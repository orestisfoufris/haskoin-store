{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
module Network.Haskoin.Store.Data.ImportDB where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Reader                (ReaderT)
import qualified Control.Monad.Reader                as R
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString.Short               as B.Short
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.IntMap.Strict                  (IntMap)
import qualified Data.IntMap.Strict                  as I
import           Data.List
import           Data.Maybe
import           Database.RocksDB                    as R
import           Database.RocksDB.Query              as R
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.RocksDB
import           Network.Haskoin.Store.Data.STM
import           UnliftIO

data ImportDB = ImportDB
    { importRocksDB    :: !(ReadOptions, DB)
    , importHashMap    :: !(TVar HashMapDB)
    , importUnspentMap :: !(TVar UnspentMap)
    , importBalanceMap :: !(TVar BalanceMap)
    }

runImportDB ::
       (MonadError e m, MonadIO m)
    => DB
    -> TVar UnspentMap
    -> TVar BalanceMap
    -> ReaderT ImportDB m a
    -> m a
runImportDB db um bm f = do
    hm <- newTVarIO emptyHashMapDB
    x <-
        R.runReaderT
            f
            ImportDB
                { importRocksDB = (defaultReadOptions, db)
                , importHashMap = hm
                , importUnspentMap = um
                , importBalanceMap = bm
                }
    ops <- hashMapOps <$> readTVarIO hm
    writeBatch db ops
    return x

hashMapOps :: HashMapDB -> [BatchOp]
hashMapOps db =
    bestBlockOp (hBest db) <>
    blockHashOps (hBlock db) <>
    blockHeightOps (hHeight db) <>
    txOps (hTx db) <>
    spenderOps (hSpender db) <>
    balOps (hBalance db) <>
    addrTxOps (hAddrTx db) <>
    addrOutOps (hAddrOut db) <>
    mempoolOps (hMempool db) <>
    unspentOps (hUnspent db)

bestBlockOp :: Maybe BlockHash -> [BatchOp]
bestBlockOp Nothing  = []
bestBlockOp (Just b) = [insertOp BestKey b]

blockHashOps :: HashMap BlockHash BlockData -> [BatchOp]
blockHashOps = map (uncurry f) . M.toList
  where
    f = insertOp . BlockKey

blockHeightOps :: HashMap BlockHeight [BlockHash] -> [BatchOp]
blockHeightOps = map (uncurry f) . M.toList
  where
    f = insertOp . HeightKey

txOps :: HashMap TxHash TxData -> [BatchOp]
txOps = map (uncurry f) . M.toList
  where
    f = insertOp . TxKey

spenderOps :: HashMap TxHash (IntMap (Maybe Spender)) -> [BatchOp]
spenderOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just s) = insertOp (SpenderKey (OutPoint h (fromIntegral i))) s
    g h i Nothing  = deleteOp (SpenderKey (OutPoint h (fromIntegral i)))

balOps :: HashMap Address BalVal -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f = insertOp . BalKey

addrTxOps ::
       HashMap Address (HashMap BlockRef (HashMap TxHash Bool)) -> [BatchOp]
addrTxOps = concat . concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a b = map (uncurry (h a b)) . M.toList
    h a b t True =
        insertOp
            (AddrTxKey
                 { addrTxKeyA = a
                 , addrTxKeyT =
                       BlockTx
                           { blockTxBlock = b
                           , blockTxHash = t
                           }
                 })
            ()
    h a b t False =
        deleteOp
            AddrTxKey
                { addrTxKeyA = a
                , addrTxKeyT =
                      BlockTx
                          { blockTxBlock = b
                          , blockTxHash = t
                          }
                }

addrOutOps ::
       HashMap Address (HashMap BlockRef (HashMap OutPoint (Maybe OutVal)))
    -> [BatchOp]
addrOutOps = concat . concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a b = map (uncurry (h a b)) . M.toList
    h a b p (Just l) =
        insertOp
            (AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p})
            l
    h a b p Nothing =
        deleteOp AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p}

mempoolOps ::
       HashMap PreciseUnixTime (HashMap TxHash Bool) -> [BatchOp]
mempoolOps = concatMap (uncurry f) . M.toList
  where
    f u = map (uncurry (g u)) . M.toList
    g u t True  = insertOp (MemKey u t) ()
    g u t False = deleteOp (MemKey u t)

unspentOps :: HashMap TxHash (IntMap (Maybe Unspent)) -> [BatchOp]
unspentOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just u) =
        insertOp
            (UnspentKey (OutPoint h (fromIntegral i)))
            UnspentVal
                { unspentValAmount = unspentAmount u
                , unspentValBlock = unspentBlock u
                , unspentValScript = B.Short.fromShort (unspentScript u)
                }
    g h i Nothing = deleteOp (UnspentKey (OutPoint h (fromIntegral i)))

isInitializedI :: MonadIO m => ImportDB -> m (Either InitException Bool)
isInitializedI ImportDB {importRocksDB = db} =
    uncurry withBlockDB db isInitialized

setInitI :: MonadIO m => ImportDB -> m ()
setInitI ImportDB {importRocksDB = (_, db), importHashMap = hm} = do
    atomically $ withBlockSTM hm setInit
    setInitDB db

setBestI :: MonadIO m => BlockHash -> ImportDB -> m ()
setBestI bh ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ setBest bh

insertBlockI :: MonadIO m => BlockData -> ImportDB -> m ()
insertBlockI b ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertBlock b

insertAtHeightI :: MonadIO m => BlockHash -> BlockHeight -> ImportDB -> m ()
insertAtHeightI b h ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertAtHeight b h

insertTxI :: MonadIO m => TxData -> ImportDB -> m ()
insertTxI t ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertTx t

insertSpenderI :: MonadIO m => OutPoint -> Spender -> ImportDB -> m ()
insertSpenderI p s ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertSpender p s

deleteSpenderI :: MonadIO m => OutPoint -> ImportDB -> m ()
deleteSpenderI p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ deleteSpender p

insertAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
insertAddrTxI a t ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertAddrTx a t

removeAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
removeAddrTxI a t ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ removeAddrTx a t

insertAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
insertAddrUnspentI a u ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertAddrUnspent a u

removeAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
removeAddrUnspentI a u ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ removeAddrUnspent a u

insertMempoolTxI :: MonadIO m => TxHash -> PreciseUnixTime -> ImportDB -> m ()
insertMempoolTxI t p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertMempoolTx t p

deleteMempoolTxI :: MonadIO m => TxHash -> PreciseUnixTime -> ImportDB -> m ()
deleteMempoolTxI t p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ deleteMempoolTx t p

getBestBlockI :: MonadIO m => ImportDB -> m (Maybe BlockHash)
getBestBlockI ImportDB {importHashMap = hm, importRocksDB = db} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = atomically $ withBlockSTM hm getBestBlock
    g = uncurry withBlockDB db getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> ImportDB -> m [BlockHash]
getBlocksAtHeightI bh ImportDB {importHashMap = hm, importRocksDB = db} = do
    xs <- atomically . withBlockSTM hm $ getBlocksAtHeight bh
    ys <- uncurry withBlockDB db $ getBlocksAtHeight bh
    return . nub $ xs <> ys

getBlockI :: MonadIO m => BlockHash -> ImportDB -> m (Maybe BlockData)
getBlockI bh ImportDB {importRocksDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = atomically . withBlockSTM hm $ getBlock bh
    g = uncurry withBlockDB db $ getBlock bh

getTxDataI ::
       MonadIO m => TxHash -> ImportDB -> m (Maybe TxData)
getTxDataI th ImportDB {importRocksDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = atomically . withBlockSTM hm $ getTxData th
    g = uncurry withBlockDB db $ getTxData th

getSpenderI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Spender)
getSpenderI op ImportDB {importRocksDB = db, importHashMap = hm} =
    getSpenderH op <$> readTVarIO hm >>= \case
        Just s -> return s
        Nothing -> uncurry withBlockDB db $ getSpender op

getSpendersI :: MonadIO m => TxHash -> ImportDB -> m (IntMap Spender)
getSpendersI t ImportDB {importRocksDB = db, importHashMap = hm} = do
    hsm <- getSpendersH t <$> readTVarIO hm
    dsm <- I.map Just <$> uncurry withBlockDB db (getSpenders t)
    return . I.map fromJust . I.filter isJust $ hsm <> dsm

getBalanceI :: MonadIO m => Address -> ImportDB -> m (Maybe Balance)
getBalanceI a ImportDB { importRocksDB = db
                       , importHashMap = hm
                       , importBalanceMap = bm
                       } =
    runMaybeT $
    MaybeT (atomically . runMaybeT $ cachemap <|> hashmap) <|> database
  where
    cachemap = MaybeT . withBalanceSTM bm $ getBalance a
    hashmap = MaybeT . withBlockSTM hm $ getBalance a
    database = MaybeT . uncurry withBlockDB db $ getBalance a

setBalanceI :: MonadIO m => Balance -> ImportDB -> m ()
setBalanceI b ImportDB {importHashMap = hm, importBalanceMap = bm} =
    atomically $ do
        withBlockSTM hm $ setBalance b
        withBalanceSTM bm $ setBalance b

getUnspentI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Unspent)
getUnspentI op ImportDB { importRocksDB = db
                        , importHashMap = hm
                        , importUnspentMap = um
                        } = do
    u <-
        atomically . runMaybeT $ do
            let x = withUnspentSTM um (getUnspent op)
                y = getUnspentH op <$> readTVar hm
            Just <$> MaybeT x <|> MaybeT y
    case u of
        Nothing -> uncurry withBlockDB db $ getUnspent op
        Just x  -> return x

addUnspentI :: MonadIO m => Unspent -> ImportDB -> m ()
addUnspentI u ImportDB {importHashMap = hm, importUnspentMap = um} =
    atomically $ do
        withBlockSTM hm $ addUnspent u
        withUnspentSTM um $ addUnspent u

delUnspentI :: MonadIO m => OutPoint -> ImportDB -> m ()
delUnspentI p ImportDB {importHashMap = hm, importUnspentMap = um} =
    atomically $ do
        withUnspentSTM um $ delUnspent p
        withBlockSTM hm $ delUnspent p

instance (MonadIO m) => StoreRead (ReaderT ImportDB m) where
    isInitialized = R.ask >>= isInitializedI
    getBestBlock = R.ask >>= getBestBlockI
    getBlocksAtHeight h = R.ask >>= getBlocksAtHeightI h
    getBlock b = R.ask >>= getBlockI b
    getTxData t = R.ask >>= getTxDataI t
    getSpender p = R.ask >>= getSpenderI p
    getSpenders t = R.ask >>= getSpendersI t

instance (MonadIO m) => StoreWrite (ReaderT ImportDB m) where
    setInit = R.ask >>= setInitI
    setBest h = R.ask >>= setBestI h
    insertBlock b = R.ask >>= insertBlockI b
    insertAtHeight b h = R.ask >>= insertAtHeightI b h
    insertTx t = R.ask >>= insertTxI t
    insertSpender p s = R.ask >>= insertSpenderI p s
    deleteSpender p = R.ask >>= deleteSpenderI p
    insertAddrTx a t = R.ask >>= insertAddrTxI a t
    removeAddrTx a t = R.ask >>= removeAddrTxI a t
    insertAddrUnspent a u = R.ask >>= insertAddrUnspentI a u
    removeAddrUnspent a u = R.ask >>= removeAddrUnspentI a u
    insertMempoolTx t p = R.ask >>= insertMempoolTxI t p
    deleteMempoolTx t p = R.ask >>= deleteMempoolTxI t p

instance (MonadIO m) => UnspentRead (ReaderT ImportDB m) where
    getUnspent a = R.ask >>= getUnspentI a

instance (MonadIO m) => UnspentWrite (ReaderT ImportDB m) where
    addUnspent u = R.ask >>= addUnspentI u
    delUnspent p = R.ask >>= delUnspentI p
    pruneUnspent = return ()

instance (MonadIO m) => BalanceRead (ReaderT ImportDB m) where
    getBalance a = R.ask >>= getBalanceI a

instance (MonadIO m) => BalanceWrite (ReaderT ImportDB m) where
    setBalance b = R.ask >>= setBalanceI b
    pruneBalance = return ()
