{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
module Network.Haskoin.Store.Block
      ( blockStore
      , getBestBlock
      , getBlocksAtHeights
      , getBlockAtHeight
      , getBlock
      , getBlocks
      , getUnspent
      , getAddrTxs
      , getAddrsTxs
      , getBalance
      , getBalances
      , getTx
      , getTxs
      , getUnspents
      , getMempool
      ) where

import           Control.Applicative
import           Control.Concurrent.NQE
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString             as BS
import           Data.List
import           Data.Map                    (Map)
import qualified Data.Map.Strict             as M
import           Data.Maybe
import           Data.Serialize              (encode)
import           Data.Set                    (Set)
import qualified Data.Set                    as S
import           Data.String
import           Data.String.Conversions
import           Database.RocksDB            (BatchOp, DB, Snapshot)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction
import           UnliftIO

data BlockRead = BlockRead
    { myBlockDB    :: !DB
    , mySelf       :: !BlockStore
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myListener   :: !(Listen BlockEvent)
    , myBaseHeight :: !(TVar BlockHeight)
    , myPeer       :: !(TVar (Maybe Peer))
    }

type MonadBlock m
     = (MonadLoggerIO m, MonadReader BlockRead m)

type OutputMap = Map OutPoint Output
type AddressMap = Map Address Balance
type TxMap = Map TxHash ImportTx

data TxStatus
    = TxValid
    | TxOrphan
    | TxLowFunds
    | TxInputSpent
    deriving (Eq, Show, Ord)

data ImportTx = ImportTx
    { importTx      :: !Tx
    , importTxBlock :: !(Maybe BlockRef)
    }

data ImportState = ImportState
    { outputMap   :: !OutputMap
    , addressMap  :: !AddressMap
    , deleteTxs   :: !(Set TxHash)
    , newTxs      :: !TxMap
    , blockAction :: !(Maybe BlockAction)
    }

type MonadImport m = MonadState ImportState m

data BlockAction = RevertBlock | ImportBlock !Block

runMonadImport :: MonadBlock m => StateT ImportState m a -> m a
runMonadImport f =
    evalStateT
        (f >>= \a -> update_database >> return a)
        ImportState
        { outputMap = M.empty
        , addressMap = M.empty
        , deleteTxs = S.empty
        , newTxs = M.empty
        , blockAction = Nothing
        }
  where
    update_database = do
        ops <-
            concat <$>
            sequence
                [getBlockOps, getBalanceOps, getDeleteTxOps, getInsertTxOps]
        db <- asks myBlockDB
        writeBatch db ops

blockStore :: (MonadUnliftIO m, MonadLoggerIO m) => BlockConfig -> m ()
blockStore BlockConfig {..} = do
    base_height_box <- liftIO (newTVarIO 0)
    peer_box <- liftIO (newTVarIO Nothing)
    runReaderT
        (load_best >> syncBlocks >> run)
        BlockRead
        { mySelf = blockConfMailbox
        , myBlockDB = blockConfDB
        , myChain = blockConfChain
        , myManager = blockConfManager
        , myListener = blockConfListener
        , myBaseHeight = base_height_box
        , myPeer = peer_box
        }
  where
    run = forever (processBlockMessage =<< receive blockConfMailbox)
    load_best =
        retrieve blockConfDB Nothing BestBlockKey >>= \case
            Nothing -> addNewBlock genesisBlock
            Just (_ :: BlockHash) ->
                getBestBlock blockConfDB Nothing >>= \BlockValue {..} -> do
                    base_height_box <- asks myBaseHeight
                    atomically $ writeTVar base_height_box blockValueHeight

getBestBlockHash :: MonadIO m => DB -> Maybe Snapshot -> m BlockHash
getBestBlockHash db snapshot =
    retrieve db snapshot BestBlockKey >>= \case
        Nothing -> throwString "Best block hash should always be available"
        Just bh -> return bh

getBestBlock :: MonadIO m => DB -> Maybe Snapshot -> m BlockValue
getBestBlock db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        getBestBlockHash db s' >>= \bh ->
            getBlock bh db s' >>= \case
                Nothing ->
                    throwString "Best block hash should always be availbale"
                Just b -> return b

getBlocksAtHeights ::
    MonadIO m => [BlockHeight] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocksAtHeights bhs db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bhs) $ \bh ->
            getBlockAtHeight bh db s'

getBlockAtHeight ::
       MonadIO m => BlockHeight -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlockAtHeight height db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = retrieve db s' (HeightKey height) >>= \case
        Nothing -> return Nothing
        Just h -> retrieve db s' (BlockKey h)

getBlocks :: MonadIO m => [BlockHash] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocks bids db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bids) $ \bid -> getBlock bid db s'

getBlock ::
       MonadIO m => BlockHash -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlock bh db snapshot = retrieve db snapshot (BlockKey bh)

getAddrsSpent ::
       MonadUnliftIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsSpent as db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrSpent a db s') (nub as)

getAddrSpent ::
       MonadUnliftIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrSpent addr db snapshot =
    matchingAsList db snapshot (MultiAddrOutputKey True addr)

getAddrsUnspent ::
       MonadUnliftIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsUnspent as db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrUnspent a db s') (nub as)

getAddrUnspent ::
       MonadUnliftIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrUnspent addr db snapshot =
    matchingAsList db snapshot (MultiAddrOutputKey False addr)

getBalances ::
    MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressBalance]
getBalances addrs db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = forM (nub addrs) $ \a -> getBalance a db s'

getBalance ::
       MonadIO m => Address -> DB -> Maybe Snapshot -> m AddressBalance
getBalance addr db s =
    retrieve db s (BalanceKey addr) >>= \case
        Just Balance {..} ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = balanceValue
                , addressBalUnconfirmed = balanceUnconfirmed
                , addressOutputCount = balanceOutputCount
                , addressSpentCount = balanceSpentCount
                }
        Nothing ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = 0
                , addressBalUnconfirmed = 0
                , addressOutputCount = 0
                , addressSpentCount = 0
                }

getMempool :: MonadUnliftIO m => DB -> Maybe Snapshot -> m [TxHash]
getMempool db snapshot = get_hashes <$> matchingAsList db snapshot MempoolKey
  where
    get_hashes mempool_txs = [tx_hash | (MempoolTx tx_hash, ()) <- mempool_txs]

getTxs :: MonadUnliftIO m => [TxHash] -> DB -> Maybe Snapshot -> m [DetailedTx]
getTxs ths db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap catMaybes . forM (nub ths) $ \th -> getTx th db s'

getTx ::
       MonadUnliftIO m => TxHash -> DB -> Maybe Snapshot -> m (Maybe DetailedTx)
getTx th db s = do
    xs <- matchingAsList db s (BaseTxKey th)
    case find_tx xs of
        Just TxRecord {..} ->
            let os = map (uncurry output) (filter_outputs xs)
                is = map (input txValuePrevOuts) (txIn txValue)
            in return $
               Just
                   DetailedTx
                   { detailedTxData = txValue
                   , detailedTxFee = fee is os
                   , detailedTxBlock = txValueBlock
                   , detailedTxInputs = is
                   , detailedTxOutputs = os
                   }
        Nothing -> return Nothing
  where
    fee is os =
        if any isCoinbase is
            then 0
            else sum (map detInValue is) - sum (map detOutValue os)
    input prevs TxIn {..} =
        if outPointHash prevOutput == zero
            then DetailedCoinbase
                 { detInOutPoint = prevOutput
                 , detInSequence = txInSequence
                 , detInSigScript = scriptInput
                 }
            else let PrevOut {..} =
                         fromMaybe
                             (error "Could not locate previous output")
                             (lookup prevOutput prevs)
                 in DetailedInput
                    { detInOutPoint = prevOutput
                    , detInSequence = txInSequence
                    , detInSigScript = scriptInput
                    , detInPkScript = prevOutScript
                    , detInValue = prevOutValue
                    , detInBlock = prevOutBlock
                    }
    output OutPoint {..} Output {..} =
        DetailedOutput
        { detOutValue = outputValue
        , detOutScript = outScript
        , detOutSpender = outSpender
        }
    find_tx xs =
        listToMaybe
            [ t
            | (k, v) <- xs
            , case k of
                  MultiTxKey {} -> True
                  _             -> False
            , let MultiTx t = v
            ]
    filter_outputs xs =
        [ (p, o)
        | (k, v) <- xs
        , case (k, v) of
              (MultiTxKeyOutput {}, MultiTxOutput {}) -> True
              _                                       -> False
        , let MultiTxKeyOutput (OutputKey p) = k
        , let MultiTxOutput o = v
        ]

getOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m (Maybe Output)
getOutput out_point = runMaybeT $ MaybeT map_lookup <|> MaybeT db_lookup
  where
    map_lookup = M.lookup out_point <$> gets outputMap
    db_key = OutputKey out_point
    db_lookup = asks myBlockDB >>= \db -> retrieve db Nothing db_key

getAddress :: (MonadBlock m, MonadImport m) => Address -> m Balance
getAddress address =
    fromMaybe emptyBalance <$>
    runMaybeT (MaybeT map_lookup <|> MaybeT db_lookup)
  where
    map_lookup = M.lookup address <$> gets addressMap
    db_key = BalanceKey address
    db_lookup = asks myBlockDB >>= \db -> retrieve db Nothing db_key

getDeleteTxs :: MonadImport m => m (Set TxHash)
getDeleteTxs = gets deleteTxs

shouldDelete :: MonadImport m => TxHash -> m Bool
shouldDelete tx_hash = S.member tx_hash <$> getDeleteTxs

addBlock :: MonadImport m => Block -> m ()
addBlock block = modify $ \s -> s {blockAction = Just (ImportBlock block)}

revertBlock :: MonadImport m => m ()
revertBlock = modify $ \s -> s {blockAction = Just RevertBlock}

deleteTx :: MonadImport m => TxHash -> m ()
deleteTx tx_hash =
    modify $ \s -> s {deleteTxs = S.insert tx_hash (deleteTxs s)}

insertTx :: MonadImport m => Tx -> Maybe BlockRef -> m ()
insertTx tx maybe_block_ref =
    modify $ \s -> s {newTxs = M.insert (txHash tx) import_tx (newTxs s)}
  where
    import_tx = ImportTx {importTx = tx, importTxBlock = maybe_block_ref}

updateOutput :: MonadImport m => OutPoint -> Output -> m ()
updateOutput out_point output =
    modify $ \s -> s {outputMap = M.insert out_point output (outputMap s)}

updateAddress :: MonadImport m => Address -> Balance -> m ()
updateAddress address balance =
    modify $ \s -> s {addressMap = M.insert address balance (addressMap s)}

spendOutput :: (MonadBlock m, MonadImport m) => OutPoint -> Spender -> m ()
spendOutput out_point spender@Spender {..} =
    void . runMaybeT $ do
        guard (out_point /= nullOutPoint)
        output@Output {..} <-
            getOutput out_point >>= \case
                Nothing -> throwString "Could not get output to spend"
                Just output -> return output
        when (isJust outSpender) $
            throwString "Output to spend is already spent"
        updateOutput out_point output {outSpender = Just spender}
        address <- MaybeT (return (scriptToAddressBS outScript))
        balance@Balance {..} <- getAddress address
        updateAddress address $
            if isJust spenderBlock
                then balance
                     { balanceValue = balanceValue - outputValue
                     , balanceSpentCount = balanceSpentCount + 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed - fromIntegral outputValue
                     , balanceSpentCount = balanceSpentCount + 1
                     }

unspendOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m ()
unspendOutput out_point =
    void . runMaybeT $ do
        guard (out_point /= nullOutPoint)
        output@Output {..} <- getOutput out_point >>= \case
            Nothing -> throwString "Could not get output to unspend"
            Just output -> return output
        Spender {..} <- MaybeT (return outSpender)
        updateOutput out_point output {outSpender = Nothing}
        address <- MaybeT (return (scriptToAddressBS outScript))
        balance@Balance {..} <- getAddress address
        updateAddress address $
            if isJust spenderBlock
                then balance
                     { balanceValue = balanceValue + outputValue
                     , balanceSpentCount = balanceSpentCount - 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed + fromIntegral outputValue
                     , balanceSpentCount = balanceSpentCount - 1
                     }

removeOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m ()
removeOutput out_point@OutPoint {..} =
    void . runMaybeT $ do
        Output {..} <-
            getOutput out_point >>= \case
                Nothing ->
                    throwString $
                    "Could not get output to remove: " <> show out_point
                Just o -> return o
        when (isJust outSpender) . throwString $
            "Cannot delete output because it is spent: " <> show out_point
        address <- MaybeT (return (scriptToAddressBS outScript))
        balance@Balance {..} <- getAddress address
        updateAddress address $
            if isJust outBlock
                then balance
                     { balanceValue = balanceValue - outputValue
                     , balanceOutputCount = balanceOutputCount - 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed - fromIntegral outputValue
                     , balanceOutputCount = balanceOutputCount - 1
                     }

addOutput :: (MonadBlock m, MonadImport m) => OutPoint -> Output -> m ()
addOutput out_point@OutPoint {..} output@Output {..} =
    void . runMaybeT $ do
        updateOutput out_point output
        address <- MaybeT (return (scriptToAddressBS outScript))
        balance@Balance {..} <- getAddress address
        updateAddress address $
            if isJust outBlock
                then balance
                     { balanceValue = balanceValue + outputValue
                     , balanceOutputCount = balanceOutputCount + 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed + fromIntegral outputValue
                     , balanceOutputCount = balanceOutputCount + 1
                     }

getTxRecord :: MonadBlock m => TxHash -> m (Maybe TxRecord)
getTxRecord tx_hash =
    asks myBlockDB >>= \db -> retrieve db Nothing (TxKey tx_hash)

deleteTransaction ::
       (MonadBlock m, MonadImport m)
    => TxHash
    -> m ()
deleteTransaction tx_hash = do
    $(logInfo) $ logMe <> "Deleting transaction: " <> logShow tx_hash
    void . runMaybeT $ do
        shouldDelete tx_hash >>= \d ->
            when d $ do
                $(logInfo) $
                    logMe <> "Transaction already scheduled for removal: " <>
                    logShow tx_hash
                empty
        TxRecord {..} <-
            getTxRecord tx_hash >>= \case
                Nothing ->
                    throwString $
                    "Could not get transaction to delete: " <> show tx_hash
                Just r -> return r
        let n_out = length (txOut txValue)
            prevs = map prevOutput (txIn txValue)
        remove_spenders n_out
        remove_outputs n_out
        unspend_inputs prevs
        deleteTx tx_hash
  where
    remove_spenders n_out =
        forM_ (take n_out [0 ..]) $ \i ->
            let out_point = OutPoint tx_hash i
            in getOutput out_point >>= \case
                   Nothing ->
                       throwString $
                       "Could not get spent output: " <> show out_point
                   Just Output {outSpender = Just Spender {..}} -> do
                       $(logInfo) $
                           logMe <> "Recursively deleting transaction: " <>
                           logShow spenderHash
                       deleteTransaction spenderHash
                   Just _ -> return ()
    remove_outputs n_out =
        mapM_ (removeOutput . OutPoint tx_hash) (take n_out [0 ..])
    unspend_inputs = mapM_ unspendOutput

addNewBlock :: MonadBlock m => Block -> m ()
addNewBlock block@Block {..} =
    runMonadImport $ do
        new_height <- get_new_height
        import_txs new_height
        addBlock block
  where
    import_txs new_height =
        mapM_
            (uncurry (import_tx (BlockRef new_hash new_height)))
            (zip [0 ..] blockTxns)
    import_tx block_ref i tx = importTransaction tx (Just (block_ref i))
    new_hash = headerHash blockHeader
    prev_block = prevBlock blockHeader
    get_new_height =
        if blockHeader == genesisHeader
            then return 0
            else do
                db <- asks myBlockDB
                best <- getBestBlock db Nothing
                let best_hash = headerHash (blockValueHeader best)
                when (prev_block /= best_hash) . throwString $
                    "Block does not build on best: " <> show new_hash
                return $ blockValueHeight best + 1

getBlockOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
getBlockOps =
    gets blockAction >>= \case
        Nothing -> return []
        Just RevertBlock -> get_block_remove_ops
        Just (ImportBlock block) -> get_block_insert_ops block
  where
    get_block_insert_ops block@Block {..} = do
        let block_hash = headerHash blockHeader
        ch <- asks myChain
        bn <-
            chainGetBlock block_hash ch >>= \case
                Just bn -> return bn
                Nothing ->
                    throwString $
                    "Could not obtain block from chain: " <> logShow block_hash
        let block_value =
                BlockValue
                { blockValueHeight = nodeHeight bn
                , blockValueWork = nodeWork bn
                , blockValueHeader = nodeHeader bn
                , blockValueSize = fromIntegral (BS.length (encode block))
                , blockValueTxs = map txHash blockTxns
                }
        return
            [ insertOp (BlockKey block_hash) block_value
            , insertOp (HeightKey (nodeHeight bn)) block_hash
            , insertOp BestBlockKey block_hash
            ]
    get_block_remove_ops = do
        db <- asks myBlockDB
        BlockValue {..} <- getBestBlock db Nothing
        let block_hash = headerHash blockValueHeader
            block_key = BlockKey block_hash
            height_key = HeightKey blockValueHeight
            prev_block = prevBlock blockValueHeader
        return
            [ deleteOp block_key
            , deleteOp height_key
            , insertOp BestBlockKey prev_block
            ]

outputOps :: (MonadBlock m, MonadImport m) => OutPoint -> m [BatchOp]
outputOps out_point@OutPoint {..}
    | out_point == nullOutPoint = return []
    | otherwise = do
        output@Output {..} <-
            getOutput out_point >>= \case
                Nothing ->
                    throwString $
                    "Could not get output to unspend: " <> show out_point
                Just o -> return o
        let output_op = insertOp (OutputKey out_point) output
            addr_ops = addressOutOps out_point output False
        return $ output_op : addr_ops

addressOutOps :: OutPoint -> Output -> Bool -> [BatchOp]
addressOutOps out_point output@Output {..} del =
    case scriptToAddressBS outScript of
        Nothing -> []
        Just address ->
            let key =
                    AddrOutputKey
                    { addrOutputSpent = isJust outSpender
                    , addrOutputAddress = address
                    , addrOutputHeight = blockRefHeight <$> outBlock
                    , addrOutPoint = out_point
                    }
                key_mempool = key {addrOutputHeight = Nothing}
                key_delete = key {addrOutputSpent = isNothing outSpender}
                key_delete_mempool = key_delete {addrOutputHeight = Nothing}
                op =
                    if del
                        then deleteOp key
                        else insertOp key output
            in if isJust outBlock
                   then [ op
                        , deleteOp key_delete
                        , deleteOp key_mempool
                        , deleteOp key_delete_mempool
                        ]
                   else [op, deleteOp key_delete]

deleteOutOps :: (MonadBlock m, MonadImport m) => OutPoint -> m [BatchOp]
deleteOutOps out_point@OutPoint {..} = do
    output@Output {..} <-
        getOutput out_point >>= \case
            Nothing ->
                throwString $
                "Could not get output to delete: " <> show out_point
            Just o -> return o
    let output_op = deleteOp (OutputKey out_point)
        addr_ops = addressOutOps out_point output True
    return $ output_op : addr_ops

deleteTxOps :: TxHash -> [BatchOp]
deleteTxOps tx_hash = [deleteOp (TxKey tx_hash), deleteOp (MempoolTx tx_hash)]

getSimpleTx :: MonadBlock m => TxHash -> m Tx
getSimpleTx tx_hash =
    getTxRecord tx_hash >>= \case
        Nothing -> throwString $ "Tx record not found: " <> show tx_hash
        Just TxRecord {..} -> return txValue

getTxOutPoints :: Tx -> [OutPoint]
getTxOutPoints tx@Tx {..} =
    let tx_hash = txHash tx
    in [OutPoint tx_hash i | i <- take (length txOut) [0 ..]]

getPrevOutPoints :: Tx -> [OutPoint]
getPrevOutPoints Tx {..} = map prevOutput txIn

getDeleteTxOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
getDeleteTxOps = do
    del_txs <- S.toList <$> getDeleteTxs
    txs <- mapM getSimpleTx del_txs
    let prev_outs = concatMap getPrevOutPoints txs
        tx_outs = concatMap getTxOutPoints txs
        tx_ops = concatMap deleteTxOps del_txs
    prev_out_ops <- concat <$> mapM outputOps prev_outs
    tx_out_ops <- concat <$> mapM deleteOutOps tx_outs
    return $ prev_out_ops <> tx_out_ops <> tx_ops

insertTxOps :: (MonadBlock m, MonadImport m) => ImportTx -> m [BatchOp]
insertTxOps ImportTx {..} = do
    prev_outputs <- get_prev_outputs importTx
    let key = TxKey (txHash importTx)
        mempool_key = MempoolTx (txHash importTx)
        value =
            TxRecord
            { txValueBlock = importTxBlock
            , txValue = importTx
            , txValuePrevOuts = prev_outputs
            }
    case importTxBlock of
        Nothing -> return [insertOp key value, insertOp mempool_key ()]
        Just _ -> return [insertOp key value, deleteOp mempool_key]
  where
    get_prev_outputs Tx {..} =
        forM (filter ((/= nullOutPoint) . prevOutput) txIn) $ \TxIn {..} -> do
            Output {..} <-
                getOutput prevOutput >>= \case
                    Nothing ->
                        throwString "Cannot get output to import transaction"
                    Just out -> return out
            return
                ( prevOutput
                , PrevOut
                  { prevOutValue = outputValue
                  , prevOutBlock = outBlock
                  , prevOutScript = outScript
                  })

getInsertTxOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
getInsertTxOps = do
    new_txs <- M.elems <$> gets newTxs
    let txs = map importTx new_txs
    let prev_outs = concatMap getPrevOutPoints txs
        tx_outs = concatMap getTxOutPoints txs
    prev_out_ops <- concat <$> mapM outputOps prev_outs
    tx_out_ops <- concat <$> mapM outputOps tx_outs
    tx_ops <- concat <$> mapM insertTxOps new_txs
    return $ prev_out_ops <> tx_out_ops <> tx_ops

getBalanceOps :: MonadImport m => m [BatchOp]
getBalanceOps = do
    address_map <- gets addressMap
    return $ map (uncurry (insertOp . BalanceKey)) (M.toList address_map)

revertBestBlock :: MonadBlock m => m ()
revertBestBlock = do
    db <- asks myBlockDB
    BlockValue {..} <- getBestBlock db Nothing
    when
        (blockValueHeader == genesisHeader)
        (throwString "Attempted to revert genesis block")
    $(logWarn) $ logMe <> "Reverting block " <> logShow blockValueHeight
    import_txs <- mapM getSimpleTx (tail blockValueTxs)
    runMonadImport $ do
        mapM_ deleteTransaction blockValueTxs
        revertBlock
    reset_peer (blockValueHeight - 1)
    runMonadImport $ mapM_ (`importTransaction` Nothing) import_txs
  where
    reset_peer height = do
        base_height_box <- asks myBaseHeight
        peer_box <- asks myPeer
        atomically $ do
            writeTVar base_height_box height
            writeTVar peer_box Nothing

importTransaction :: (MonadBlock m, MonadImport m) => Tx -> Maybe BlockRef -> m ()
importTransaction tx maybe_block_ref =
    runExceptT validate_tx >>= \case
        Left e ->
            $(logError) $
            logMe <> "Not importing tx: " <> logShow (txHash tx) <> ": " <> e
        Right () ->
            void . runMaybeT $ do
                delete_spenders
                spend_inputs
                insert_outputs
                $(logInfo) $
                    logMe <> "Importing transaction: " <> logShow (txHash tx)
                insertTx tx maybe_block_ref
  where
    validate_tx
        | isJust maybe_block_ref = return () -- only validate unconfirmed
        | otherwise = do
            guard . isNothing =<< getTxRecord (txHash tx)
            prev_outs <-
                forM (txIn tx) $ \TxIn {..} ->
                    getOutput prevOutput >>= \case
                        Nothing -> throwError "Previous output not found"
                        Just output -> return output
            when (any (isJust . outSpender) prev_outs) $
                throwError "Double-spend attempt rejected"
            let sum_inputs = sum (map outputValue prev_outs)
                sum_outputs = sum (map outValue (txOut tx))
            when (sum_outputs > sum_inputs) $
                throwError "Spends more than available"
    delete_spenders =
        forM_ (txIn tx) $ \TxIn {..} ->
            getOutput prevOutput >>= \case
                Nothing ->
                    unless (prevOutput == nullOutPoint) . throwString $
                    "Could not get output for transaction being imported: " <>
                    show (txHash tx)
                Just Output {outSpender = Just Spender {..}} -> do
                    $(logInfo) $
                        logMe <> "Deleting transaction to free its inputs: " <>
                        logShow spenderHash
                    deleteTransaction spenderHash
                _ -> return ()
    spend_inputs =
        forM_ (zip [0 ..] (txIn tx)) $ \(i, TxIn {..}) ->
            spendOutput
                prevOutput
                Spender
                { spenderHash = txHash tx
                , spenderIndex = i
                , spenderBlock = maybe_block_ref
                }
    insert_outputs =
        forM_ (zip [0 ..] (txOut tx)) $ \(i, TxOut {..}) ->
            addOutput
                OutPoint {outPointHash = txHash tx, outPointIndex = i}
                Output
                { outputValue = outValue
                , outBlock = maybe_block_ref
                , outScript = scriptOutput
                , outSpender = Nothing
                }

syncBlocks :: MonadBlock m => m ()
syncBlocks = void (runMaybeT sync)
  where
    sync = do
        (best_height, chain_best) <- revert_if_needed
        let chain_height = nodeHeight chain_best
        base_height_box <- asks myBaseHeight
        when (best_height == chain_height) $ do
            reset_peer best_height
            fail "Already synced"
        base_height <- readTVarIO base_height_box
        p <- get_peer
        when (base_height > best_height + 500) $ fail "Enough blocks pending"
        when (base_height >= chain_height) $
            fail "All blocks have been already requested"
        ch <- asks myChain
        let sync_lowest = min chain_height (base_height + 1)
            sync_highest = min chain_height (base_height + 501)
        sync_top <-
            if sync_highest == chain_height
                then return chain_best
                else chainGetAncestor sync_highest chain_best ch >>= \case
                         Nothing ->
                             throwString
                                 "Could not get syncing header from chain"
                         Just b -> return b
        sync_blocks <-
            (++ [sync_top]) <$>
            if sync_lowest == chain_height
                then return []
                else chainGetParents sync_lowest sync_top ch
        update_peer sync_highest (Just p)
        peerGetBlocks p (map (headerHash . nodeHeader) sync_blocks)
    get_peer =
        asks myPeer >>= readTVarIO >>= \case
            Just p -> return p
            Nothing ->
                asks myManager >>= managerGetPeers >>= \case
                    [] -> fail "No peer to sync against"
                    p:_ -> return p
    reset_peer best_height = update_peer best_height Nothing
    update_peer height mp = do
        base_height_box <- asks myBaseHeight
        peer_box <- asks myPeer
        atomically $ do
            writeTVar base_height_box height
            writeTVar peer_box mp
    revert_if_needed = do
        db <- asks myBlockDB
        ch <- asks myChain
        best <- getBestBlock db Nothing
        chain_best <- chainGetBest ch
        let best_hash = headerHash (blockValueHeader best)
            chain_hash = headerHash (nodeHeader chain_best)
        if best_hash == chain_hash
            then let best_height = blockValueHeight best
                 in return (best_height, chain_best)
            else chainGetBlock best_hash ch >>= \case
                     Nothing -> do
                         revertBestBlock
                         revert_if_needed
                     Just best_node -> do
                         split_hash <-
                             headerHash . nodeHeader <$>
                             chainGetSplitBlock chain_best best_node ch
                         best_height <- revert_until split_hash
                         return (best_height, chain_best)
    revert_until split = do
        db <- asks myBlockDB
        best <- getBestBlock db Nothing
        let best_hash = headerHash (blockValueHeader best)
            best_height = blockValueHeight best
        if best_hash == split
            then return best_height
            else do
                revertBestBlock
                revert_until split

importBlock :: (MonadError String m, MonadBlock m) => Block -> m ()
importBlock block@Block {..} = do
    bn <-
        asks myChain >>= chainGetBlock (headerHash blockHeader) >>= \case
            Just bn -> return bn
            Nothing -> throwString "Could not obtain block from chain"
    best <- asks myBlockDB >>= \db -> getBestBlock db Nothing
    let best_hash = headerHash (blockValueHeader best)
        prev_hash = prevBlock blockHeader
    when (prev_hash /= best_hash) (throwError "does not build on best")
    $(logInfo) $ logMe <> "Importing block " <> logShow (nodeHeight bn)
    addNewBlock block
    asks myListener >>= atomically . ($ BestBlock (headerHash blockHeader))

processBlockMessage :: MonadBlock m => BlockMessage -> m ()

processBlockMessage (BlockChainNew _) = syncBlocks

processBlockMessage (BlockPeerConnect _) = syncBlocks

processBlockMessage (BlockReceived _ b) =
    runExceptT (importBlock b) >>= \case
        Left e -> do
            let hash = headerHash (blockHeader b)
            $(logError) $
                logMe <> "Could not import block " <> logShow hash <> ": " <>
                fromString e
        Right () -> syncBlocks

processBlockMessage (TxReceived _ tx) =
    runMonadImport $ importTransaction tx Nothing

processBlockMessage (BlockPeerDisconnect p) = do
    peer_box <- asks myPeer
    base_height_box <- asks myBaseHeight
    db <- asks myBlockDB
    best <- getBestBlock db Nothing
    is_my_peer <-
        atomically $
        readTVar peer_box >>= \x ->
            if x == Just p
                then do
                    writeTVar peer_box Nothing
                    writeTVar base_height_box (blockValueHeight best)
                    return True
                else return False
    when is_my_peer syncBlocks

processBlockMessage (BlockNotReceived p h) = do
    $(logError) $ logMe <> "Block not found: " <> cs (show h)
    mgr <- asks myManager
    managerKill (PeerMisbehaving "Block not found") p mgr

processBlockMessage _ = return ()

getAddrTxs :: MonadUnliftIO m => Address -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrTxs addr = getAddrsTxs [addr]

getAddrsTxs :: MonadUnliftIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrsTxs addrs db s =
    case s of
        Nothing -> R.withSnapshot db $ g . Just
        Just _  -> g s
  where
    g s' = do
        us <- getAddrsUnspent addrs db s'
        ss <- getAddrsSpent addrs db s'
        let utx =
                [ AddressTxOut
                { addressTxPkScript = outScript
                , addressTxId = outPointHash addrOutPoint
                , addressTxAmount = fromIntegral outputValue
                , addressTxBlock = outBlock
                , addressTxVout = outPointIndex addrOutPoint
                }
                | (AddrOutputKey {..}, Output {..}) <- us
                ]
            stx =
                [ AddressTxOut
                { addressTxPkScript = outScript
                , addressTxId = outPointHash addrOutPoint
                , addressTxAmount = fromIntegral outputValue
                , addressTxBlock = outBlock
                , addressTxVout = outPointIndex addrOutPoint
                }
                | (AddrOutputKey {..}, Output {..}) <- ss
                ]
            itx =
                [ AddressTxIn
                { addressTxPkScript = outScript
                , addressTxId = spenderHash
                , addressTxAmount = -fromIntegral outputValue
                , addressTxBlock = spenderBlock
                , addressTxVin = spenderIndex
                }
                | (AddrOutputKey {..}, Output {..}) <- ss
                , let Spender {..} = fromMaybe e outSpender
                ]
        return $ sort (itx ++ stx ++ utx)
    e = error "Could not get spender from spent output"

getUnspents :: MonadUnliftIO m => [Address] -> DB -> Maybe Snapshot -> m [Unspent]
getUnspents addrs db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap (sort . concat) $ forM addrs $ \addr -> getUnspent addr db s'

getUnspent :: MonadUnliftIO m => Address -> DB -> Maybe Snapshot -> m [Unspent]
getUnspent addr db s = do
    xs <- getAddrUnspent addr db s
    return $ map (uncurry to_unspent) xs
  where
    to_unspent AddrOutputKey {..} Output {..} =
        Unspent
        { unspentPkScript = outScript
        , unspentTxId = outPointHash addrOutPoint
        , unspentIndex = outPointIndex addrOutPoint
        , unspentValue = outputValue
        , unspentBlock = outBlock
        }
    to_unspent _ _ = error "Error decoding AddrOutputKey data structure"

logMe :: IsString a => a
logMe = "[Block] "

zero :: TxHash
zero = "0000000000000000000000000000000000000000000000000000000000000000"
