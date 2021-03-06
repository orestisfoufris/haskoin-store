{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Store.Data.ImportDB where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Logger
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
import           Data.String.Conversions             (cs)
import           Database.RocksDB                    as R
import           Database.RocksDB.Query              as R
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.Cached
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.Memory
import           Network.Haskoin.Store.Data.RocksDB
import           UnliftIO

data ImportDB = ImportDB
    { importLayeredDB :: !LayeredDB
    , importHashMap   :: !(TVar BlockMem)
    }

runImportDB ::
       (MonadError e m, MonadLoggerIO m)
    => LayeredDB
    -> ReaderT ImportDB m a
    -> m a
runImportDB ldb f = do
    hm <- newTVarIO emptyBlockMem
    x <- R.runReaderT f ImportDB {importLayeredDB = ldb, importHashMap = hm}
    ops <- hashMapOps <$> readTVarIO hm
    $(logDebugS) "ImportDB" "Committing changes to database and cache..."
    case cache of
        Just BlockDB {blockDB = cdb} -> do
            cops <- cacheMapOps <$> readTVarIO hm
            let del Put {} = False
                del Del {} = True
                (delcops, addcops) = partition del cops
            writeBatch cdb delcops
            writeBatch db ops
            writeBatch cdb addcops
        Nothing -> writeBatch db ops
    $(logDebugS) "ImportDB" "Finished committing changes to database and cache"
    return x
  where
    LayeredDB {layeredDB = BlockDB {blockDB = db}, layeredCache = cache} = ldb

hashMapOps :: BlockMem -> [BatchOp]
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
    orphanOps (hOrphans db) <>
    unspentOps (hUnspent db)

cacheMapOps :: BlockMem -> [BatchOp]
cacheMapOps db =
    balOps (hBalance db) <> mempoolOps (hMempool db) <> unspentOps (hUnspent db)

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
       HashMap UnixTime (HashMap TxHash Bool) -> [BatchOp]
mempoolOps = concatMap (uncurry f) . M.toList
  where
    f u = map (uncurry (g u)) . M.toList
    g u t True  = insertOp (MemKey u t) ()
    g u t False = deleteOp (MemKey u t)

orphanOps :: HashMap TxHash (Maybe (UnixTime, Tx)) -> [BatchOp]
orphanOps = map (uncurry f) . M.toList
  where
    f h (Just x) = insertOp (OrphanKey h) x
    f h Nothing  = deleteOp (OrphanKey h)

unspentOps :: HashMap TxHash (IntMap (Maybe UnspentVal)) -> [BatchOp]
unspentOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just u) = insertOp (UnspentKey (OutPoint h (fromIntegral i))) u
    g h i Nothing  = deleteOp (UnspentKey (OutPoint h (fromIntegral i)))

isInitializedI :: MonadIO m => ImportDB -> m (Either InitException Bool)
isInitializedI ImportDB {importLayeredDB = ldb} =
    withLayeredDB ldb isInitialized

setInitI :: MonadIO m => ImportDB -> m ()
setInitI ImportDB { importLayeredDB = LayeredDB {layeredDB = BlockDB {blockDB = db}}
                  , importHashMap = hm
                  } = do
    withBlockMem hm setInit
    setInitDB db

setBestI :: MonadIO m => BlockHash -> ImportDB -> m ()
setBestI bh ImportDB {importHashMap = hm} =
    withBlockMem hm $ setBest bh

insertBlockI :: MonadIO m => BlockData -> ImportDB -> m ()
insertBlockI b ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertBlock b

insertAtHeightI :: MonadIO m => BlockHash -> BlockHeight -> ImportDB -> m ()
insertAtHeightI b h ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertAtHeight b h

insertTxI :: MonadIO m => TxData -> ImportDB -> m ()
insertTxI t ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertTx t

insertSpenderI :: MonadIO m => OutPoint -> Spender -> ImportDB -> m ()
insertSpenderI p s ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertSpender p s

deleteSpenderI :: MonadIO m => OutPoint -> ImportDB -> m ()
deleteSpenderI p ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteSpender p

insertAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
insertAddrTxI a t ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertAddrTx a t

deleteAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
deleteAddrTxI a t ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteAddrTx a t

insertAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
insertAddrUnspentI a u ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertAddrUnspent a u

deleteAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
deleteAddrUnspentI a u ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteAddrUnspent a u

insertMempoolTxI :: MonadIO m => TxHash -> UnixTime -> ImportDB -> m ()
insertMempoolTxI t p ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertMempoolTx t p

deleteMempoolTxI :: MonadIO m => TxHash -> UnixTime -> ImportDB -> m ()
deleteMempoolTxI t p ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteMempoolTx t p

insertOrphanTxI :: MonadIO m => Tx -> UnixTime -> ImportDB -> m ()
insertOrphanTxI t p ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertOrphanTx t p

deleteOrphanTxI :: MonadIO m => TxHash -> ImportDB -> m ()
deleteOrphanTxI t ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteOrphanTx t

getBestBlockI :: MonadIO m => ImportDB -> m (Maybe BlockHash)
getBestBlockI ImportDB {importHashMap = hm, importLayeredDB = db} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm getBestBlock
    g = withLayeredDB db getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> ImportDB -> m [BlockHash]
getBlocksAtHeightI bh ImportDB {importHashMap = hm, importLayeredDB = db} = do
    xs <- withBlockMem hm $ getBlocksAtHeight bh
    ys <- withLayeredDB db $ getBlocksAtHeight bh
    return . nub $ xs <> ys

getBlockI :: MonadIO m => BlockHash -> ImportDB -> m (Maybe BlockData)
getBlockI bh ImportDB {importLayeredDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm $ getBlock bh
    g = withLayeredDB db $ getBlock bh

getTxDataI ::
       MonadIO m => TxHash -> ImportDB -> m (Maybe TxData)
getTxDataI th ImportDB {importLayeredDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm $ getTxData th
    g = withLayeredDB db $ getTxData th

getOrphanTxI :: MonadIO m => TxHash -> ImportDB -> m (Maybe (UnixTime, Tx))
getOrphanTxI h ImportDB {importLayeredDB = db, importHashMap = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getOrphanTxH h <$> readTVarIO hm
    g = Just <$> withLayeredDB db (getOrphanTx h)

getSpenderI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Spender)
getSpenderI op ImportDB {importLayeredDB = db, importHashMap = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getSpenderH op <$> readTVarIO hm
    g = Just <$> withLayeredDB db (getSpender op)

getSpendersI :: MonadIO m => TxHash -> ImportDB -> m (IntMap Spender)
getSpendersI t ImportDB {importLayeredDB = db, importHashMap = hm} = do
    hsm <- getSpendersH t <$> readTVarIO hm
    dsm <- I.map Just <$> withLayeredDB db (getSpenders t)
    return . I.map fromJust . I.filter isJust $ hsm <> dsm

getBalanceI :: MonadIO m => Address -> ImportDB -> m (Maybe Balance)
getBalanceI a ImportDB {importLayeredDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm $ getBalance a
    g = withLayeredDB db $ getBalance a

setBalanceI :: MonadIO m => Balance -> ImportDB -> m ()
setBalanceI b ImportDB {importHashMap = hm} =
    withBlockMem hm $ setBalance b

getUnspentI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Unspent)
getUnspentI op ImportDB {importLayeredDB = db, importHashMap = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getUnspentH op <$> readTVarIO hm
    g = Just <$> withLayeredDB db (getUnspent op)

insertUnspentI :: MonadIO m => Unspent -> ImportDB -> m ()
insertUnspentI u ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertUnspent u

deleteUnspentI :: MonadIO m => OutPoint -> ImportDB -> m ()
deleteUnspentI p ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteUnspent p

getMempoolI ::
       MonadIO m
    => Maybe UnixTime
    -> ImportDB
    -> ConduitT () (UnixTime, TxHash) m ()
getMempoolI mpu ImportDB {importHashMap = hm, importLayeredDB = db} = do
    h <- hMempool <$> readTVarIO hm
    let hmap =
            M.fromList . filter tfilter $
            concatMap
                (\(u, l) -> map (\(t, b) -> ((u, t), b)) (M.toList l))
                (M.toList h)
    dmap <-
        fmap M.fromList . liftIO . runResourceT . withLayeredDB db . runConduit $
        getMempool mpu .| mapC (, True) .| sinkList
    let rmap = M.filter id (M.union hmap dmap)
    yieldMany $ sortBy (flip compare) (M.keys rmap)
  where
    tfilter =
        case mpu of
            Just x -> (<= x) . fst . fst
            Nothing -> const True

instance MonadIO m => StoreRead (ReaderT ImportDB m) where
    isInitialized = R.ask >>= isInitializedI
    getBestBlock = R.ask >>= getBestBlockI
    getBlocksAtHeight h = R.ask >>= getBlocksAtHeightI h
    getBlock b = R.ask >>= getBlockI b
    getTxData t = R.ask >>= getTxDataI t
    getSpender p = R.ask >>= getSpenderI p
    getSpenders t = R.ask >>= getSpendersI t
    getOrphanTx h = R.ask >>= getOrphanTxI h
    getUnspent a = R.ask >>= getUnspentI a
    getBalance a = R.ask >>= getBalanceI a

instance MonadIO m => StoreWrite (ReaderT ImportDB m) where
    setInit = R.ask >>= setInitI
    setBest h = R.ask >>= setBestI h
    insertBlock b = R.ask >>= insertBlockI b
    insertAtHeight b h = R.ask >>= insertAtHeightI b h
    insertTx t = R.ask >>= insertTxI t
    insertSpender p s = R.ask >>= insertSpenderI p s
    deleteSpender p = R.ask >>= deleteSpenderI p
    insertAddrTx a t = R.ask >>= insertAddrTxI a t
    deleteAddrTx a t = R.ask >>= deleteAddrTxI a t
    insertAddrUnspent a u = R.ask >>= insertAddrUnspentI a u
    deleteAddrUnspent a u = R.ask >>= deleteAddrUnspentI a u
    insertMempoolTx t p = R.ask >>= insertMempoolTxI t p
    deleteMempoolTx t p = R.ask >>= deleteMempoolTxI t p
    insertOrphanTx t p = R.ask >>= insertOrphanTxI t p
    deleteOrphanTx t = R.ask >>= deleteOrphanTxI t
    insertUnspent u = R.ask >>= insertUnspentI u
    deleteUnspent p = R.ask >>= deleteUnspentI p
    setBalance b = R.ask >>= setBalanceI b

instance MonadIO m => StoreStream (ReaderT ImportDB m) where
    getMempool m = R.ask >>= getMempoolI m
    getOrphans = undefined
    getAddressUnspents a m = undefined
    getAddressTxs a m = undefined
    getAddressBalances = undefined
    getUnspents = undefined
