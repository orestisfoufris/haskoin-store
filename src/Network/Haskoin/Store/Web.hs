{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Store.Web where
import           Conduit                           hiding (runResourceT)
import           Control.Applicative               ((<|>))
import           Control.Arrow
import           Control.Exception                 ()
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader              (MonadReader, ReaderT)
import qualified Control.Monad.Reader              as R
import           Control.Monad.Trans.Maybe
import           Data.Aeson.Encoding               (encodingToLazyByteString,
                                                    fromEncoding)
import           Data.Bits
import           Data.ByteString.Builder
import qualified Data.ByteString.Lazy              as L
import qualified Data.ByteString.Lazy.Char8        as C
import           Data.Char
import           Data.Foldable
import           Data.Function
import qualified Data.HashMap.Strict               as H
import           Data.List
import           Data.Maybe
import           Data.Serialize                    as Serialize
import           Data.String.Conversions
import qualified Data.Text.Lazy                    as T
import           Data.Version
import           Data.Word                         (Word32)
import           Database.RocksDB                  as R
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.Cached
import           Network.Haskoin.Store.Messages
import           Network.HTTP.Types
import           NQE
import qualified Paths_haskoin_store               as P
import           Text.Read                         (readMaybe)
import           UnliftIO
import           UnliftIO.Resource
import           Web.Scotty.Internal.Types         (ActionT (ActionT, runAM))
import           Web.Scotty.Trans                  as S

type WebT m = ActionT Except (ReaderT LayeredDB m)

data WebConfig =
    WebConfig
        { webPort      :: !Int
        , webNetwork   :: !Network
        , webDB        :: !LayeredDB
        , webPublisher :: !(Publisher StoreEvent)
        , webStore     :: !Store
        }

instance Parsable BlockHash where
    parseParam =
        maybe (Left "could not decode block hash") Right . hexToBlockHash . cs

instance Parsable TxHash where
    parseParam =
        maybe (Left "could not decode tx hash") Right . hexToTxHash . cs

instance MonadIO m => StoreRead (WebT m) where
    isInitialized = lift isInitialized
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getSpenders = lift . getSpenders
    getOrphanTx = lift . getOrphanTx
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance

instance (MonadResource m, MonadUnliftIO m) =>
         StoreStream (WebT (ReaderT LayeredDB m)) where
    getMempool = transPipe lift . getMempool
    getOrphans = transPipe lift getOrphans
    getAddressUnspents a x = transPipe lift $ getAddressUnspents a x
    getAddressTxs a x = transPipe lift $ getAddressTxs a x
    getAddressBalances = transPipe lift getAddressBalances
    getUnspents = transPipe lift getUnspents

askDB :: Monad m => WebT m LayeredDB
askDB = lift R.ask

defHandler :: Monad m => Network -> Except -> WebT m ()
defHandler net e = do
    proto <- setupBin
    case e of
        ThingNotFound -> status status404
        BadRequest    -> status status400
        UserError _   -> status status400
        StringError _ -> status status400
        ServerError   -> status status500
    protoSerial net proto e

maybeSerial ::
       (Monad m, JsonSerial a, BinSerial a)
    => Network
    -> Bool -- ^ binary
    -> Maybe a
    -> WebT m ()
maybeSerial _ _ Nothing        = raise ThingNotFound
maybeSerial net proto (Just x) = S.raw $ serialAny net proto x

protoSerial ::
       (Monad m, JsonSerial a, BinSerial a)
    => Network
    -> Bool
    -> a
    -> WebT m ()
protoSerial net proto = S.raw . serialAny net proto

scottyBestBlock :: MonadIO m => Network -> WebT m ()
scottyBestBlock net = do
    cors
    n <- parseNoTx
    proto <- setupBin
    res <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            b <- MaybeT $ getBlock h
            return $ pruneTx n b
    maybeSerial net proto res

scottyBlock :: MonadIO m => Network -> WebT m ()
scottyBlock net = do
    cors
    block <- param "block"
    n <- parseNoTx
    proto <- setupBin
    res <-
        runMaybeT $ do
            b <- MaybeT $ getBlock block
            return $ pruneTx n b
    maybeSerial net proto res

scottyBlockHeight :: MonadIO m => Network -> WebT m ()
scottyBlockHeight net = do
    cors
    height <- param "height"
    n <- parseNoTx
    proto <- setupBin
    res <-
        fmap catMaybes $ do
            hs <- getBlocksAtHeight height
            forM hs $ \h ->
                runMaybeT $ do
                    b <- MaybeT $ getBlock h
                    return $ pruneTx n b
    protoSerial net proto res

scottyBlockHeights :: MonadIO m => Network -> WebT m ()
scottyBlockHeights net = do
    cors
    heights <- param "heights"
    n <- parseNoTx
    proto <- setupBin
    bs <- concat <$> mapM getBlocksAtHeight (nub heights)
    res <-
        fmap catMaybes . forM bs $ \bh ->
            runMaybeT $ do
                b <- MaybeT $ getBlock bh
                return $ pruneTx n b
    protoSerial net proto res

scottyBlocks :: MonadIO m => Network -> WebT m ()
scottyBlocks net = do
    cors
    blocks <- param "blocks"
    n <- parseNoTx
    proto <- setupBin
    res <-
        fmap catMaybes . forM blocks $ \bh ->
            runMaybeT $ do
                b <- MaybeT $ getBlock bh
                return $ pruneTx n b
    protoSerial net proto res

scottyMempool :: MonadUnliftIO m => Network -> WebT m ()
scottyMempool net = do
    cors
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db $
            runConduit $ getMempoolLimit l s .| streamAny net proto io
        flush'

scottyTransaction :: MonadIO m => Network -> WebT m ()
scottyTransaction net = do
    cors
    txid <- param "txid"
    proto <- setupBin
    res <- getTransaction txid
    maybeSerial net proto res

scottyRawTransaction :: MonadIO m => Bool -> WebT m ()
scottyRawTransaction hex = do
    cors
    txid <- param "txid"
    res <- getTransaction txid
    case res of
        Nothing -> raise ThingNotFound
        Just x ->
            if hex
                then text . cs . encodeHex . Serialize.encode $
                     transactionData x
                else do
                    S.setHeader "Content-Type" "application/octet-stream"
                    S.raw $ Serialize.encodeLazy (transactionData x)

scottyTxAfterHeight :: MonadIO m => Network -> WebT m ()
scottyTxAfterHeight net = do
    cors
    txid <- param "txid"
    height <- param "height"
    proto <- setupBin
    res <- cbAfterHeight 10000 height txid
    protoSerial net proto res

scottyTransactions :: MonadIO m => Network -> WebT m ()
scottyTransactions net = do
    cors
    txids <- param "txids"
    proto <- setupBin
    res <- catMaybes <$> mapM getTransaction (nub txids)
    protoSerial net proto res

scottyRawTransactions :: MonadIO m => Bool -> WebT m ()
scottyRawTransactions hex = do
    cors
    txids <- param "txids"
    res <- catMaybes <$> mapM getTransaction (nub txids)
    if hex
        then S.json $ map (encodeHex . Serialize.encode . transactionData) res
        else do
            S.setHeader "Content-Type" "application/octet-stream"
            S.raw . L.concat $ map (Serialize.encodeLazy . transactionData) res

scottyAddressTxs :: MonadUnliftIO m => Network -> Bool -> WebT m ()
scottyAddressTxs net full = do
    cors
    a <- parseAddress net
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $ f proto l s a io
        flush'
  where
    f proto l s a io
        | full = getAddressTxsFull l s a .| streamAny net proto io
        | otherwise = getAddressTxsLimit l s a .| streamAny net proto io

scottyAddressesTxs :: MonadUnliftIO m => Network -> Bool -> WebT m ()
scottyAddressesTxs net full = do
    cors
    as <- parseAddresses net
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $ f proto l s as io
        flush'
  where
    f proto l s as io
        | full = getAddressesTxsFull l s as .| streamAny net proto io
        | otherwise = getAddressesTxsLimit l s as .| streamAny net proto io

scottyAddressUnspent :: MonadUnliftIO m => Network -> WebT m ()
scottyAddressUnspent net = do
    cors
    a <- parseAddress net
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $
            getAddressUnspentsLimit l s a .| streamAny net proto io
        flush'

scottyAddressesUnspent :: MonadUnliftIO m => Network -> WebT m ()
scottyAddressesUnspent net = do
    cors
    as <- parseAddresses net
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $
            getAddressesUnspentsLimit l s as .| streamAny net proto io
        flush'

scottyAddressBalance :: MonadIO m => Network -> WebT m ()
scottyAddressBalance net = do
    cors
    address <- parseAddress net
    proto <- setupBin
    res <-
        getBalance address >>= \case
            Just b -> return b
            Nothing ->
                return
                    Balance
                        { balanceAddress = address
                        , balanceAmount = 0
                        , balanceUnspentCount = 0
                        , balanceZero = 0
                        , balanceTxCount = 0
                        , balanceTotalReceived = 0
                        }
    protoSerial net proto res

scottyAddressesBalances :: MonadIO m => Network -> WebT m ()
scottyAddressesBalances net = do
    cors
    as <- parseAddresses net
    proto <- setupBin
    let f a Nothing =
            Balance
                { balanceAddress = a
                , balanceAmount = 0
                , balanceUnspentCount = 0
                , balanceZero = 0
                , balanceTxCount = 0
                , balanceTotalReceived = 0
                }
        f _ (Just b) = b
    res <- mapM (\a -> f a <$> getBalance a) as
    protoSerial net proto res

scottyXpubBalances :: MonadUnliftIO m => Network -> WebT m ()
scottyXpubBalances net = do
    cors
    xpub <- parseXpub net
    proto <- setupBin
    db <- askDB
    res <- liftIO . runResourceT . withLayeredDB db $ xpubBals xpub
    protoSerial net proto res

scottyXpubTxs :: MonadUnliftIO m => Network -> Bool -> WebT m ()
scottyXpubTxs net full = do
    cors
    x <- parseXpub net
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    bs <- liftIO . runResourceT . withLayeredDB db $ xpubBals x
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $ f proto l s bs io
        flush'
  where
    f proto l s bs io
        | full =
            getAddressesTxsFull l s (map (balanceAddress . xPubBal) bs) .|
            streamAny net proto io
        | otherwise =
            getAddressesTxsLimit l s (map (balanceAddress . xPubBal) bs) .|
            streamAny net proto io

scottyXpubUnspents :: MonadIO m => Network -> WebT m ()
scottyXpubUnspents net = do
    cors
    x <- parseXpub net
    proto <- setupBin
    (l, s) <- parseLimits
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $
            xpubUnspentLimit net l s x .| streamAny net proto io
        flush'

scottyXpubSummary :: MonadUnliftIO m => Network -> WebT m ()
scottyXpubSummary net = do
    cors
    x <- parseXpub net
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    res <- liftIO . runResourceT . withLayeredDB db $ xpubSummary l s x
    protoSerial net proto res

scottyPostTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Store
    -> Publisher StoreEvent
    -> WebT m ()
scottyPostTx net st pub = do
    cors
    proto <- setupBin
    b <- body
    let bin = eitherToMaybe . Serialize.decode
        hex = bin <=< decodeHex . cs . C.filter (not . isSpace)
    tx <-
        case hex b <|> bin (L.toStrict b) of
            Nothing -> raise (UserError "decode tx fail")
            Just x  -> return x
    lift (publishTx net pub st tx) >>= \case
        Right () -> do
            protoSerial net proto (TxId (txHash tx))
            $(logDebugS) "Web" $
                "Success publishing tx " <> txHashToHex (txHash tx)
        Left e -> do
            case e of
                PubNoPeers          -> status status500
                PubTimeout          -> status status500
                PubPeerDisconnected -> status status500
                PubNotFound         -> status status500
                PubReject _         -> status status400
            protoSerial net proto (UserError (show e))
            $(logErrorS) "Web" $
                "Error publishing tx " <> txHashToHex (txHash tx) <> ": " <>
                cs (show e)
            finish

scottyDbStats :: MonadIO m => WebT m ()
scottyDbStats = do
    cors
    LayeredDB {layeredDB = BlockDB {blockDB = db}} <- askDB
    lift (getProperty db Stats) >>= text . cs . fromJust

scottyEvents :: MonadUnliftIO m => Network -> Publisher StoreEvent -> WebT m ()
scottyEvents net pub = do
    cors
    proto <- setupBin
    stream $ \io flush' ->
        withSubscription pub $ \sub ->
            forever $
            flush' >> receive sub >>= \se -> do
                let me =
                        case se of
                            StoreBestBlock block_hash ->
                                Just (EventBlock block_hash)
                            StoreMempoolNew tx_hash -> Just (EventTx tx_hash)
                            _ -> Nothing
                case me of
                    Nothing -> return ()
                    Just e ->
                        let bs =
                                serialAny net proto e <>
                                if proto
                                    then mempty
                                    else "\n"
                         in io (lazyByteString bs)

scottyPeers :: MonadIO m => Network -> Store -> WebT m ()
scottyPeers net st = do
    cors
    proto <- setupBin
    ps <- getPeersInformation (storeManager st)
    protoSerial net proto ps

scottyHealth :: MonadUnliftIO m => Network -> Store -> WebT m ()
scottyHealth net st = do
    cors
    proto <- setupBin
    h <- lift $ healthCheck net (storeManager st) (storeChain st)
    when (not (healthOK h) || not (healthSynced h)) $ status status503
    protoSerial net proto h

runWeb :: (MonadLoggerIO m, MonadUnliftIO m) => WebConfig -> m ()
runWeb WebConfig { webDB = db
                 , webPort = port
                 , webNetwork = net
                 , webStore = st
                 , webPublisher = pub
                 } = do
    runner <- askRunInIO
    scottyT port (runner . withLayeredDB db) $ do
        defaultHandler (defHandler net)
        S.get "/block/best" $ scottyBestBlock net
        S.get "/block/:block" $ scottyBlock net
        S.get "/block/height/:height" $ scottyBlockHeight net
        S.get "/block/heights" $ scottyBlockHeights net
        S.get "/blocks" $ scottyBlocks net
        S.get "/mempool" $ scottyMempool net
        S.get "/transaction/:txid" $ scottyTransaction net
        S.get "/transaction/:txid/hex" $ scottyRawTransaction True
        S.get "/transaction/:txid/bin" $ scottyRawTransaction False
        S.get "/transaction/:txid/after/:height" $ scottyTxAfterHeight net
        S.get "/transactions" $ scottyTransactions net
        S.get "/transactions/hex" $ scottyRawTransactions True
        S.get "/transactions/bin" $ scottyRawTransactions False
        S.get "/address/:address/transactions" $ scottyAddressTxs net False
        S.get "/address/:address/transactions/full" $ scottyAddressTxs net True
        S.get "/address/transactions" $ scottyAddressesTxs net False
        S.get "/address/transactions/full" $ scottyAddressesTxs net True
        S.get "/address/:address/unspent" $ scottyAddressUnspent net
        S.get "/address/unspent" $ scottyAddressesUnspent net
        S.get "/address/:address/balance" $ scottyAddressBalance net
        S.get "/address/balances" $ scottyAddressesBalances net
        S.get "/xpub/:xpub/balances" $ scottyXpubBalances net
        S.get "/xpub/:xpub/transactions" $ scottyXpubTxs net False
        S.get "/xpub/:xpub/transactions/full" $ scottyXpubTxs net True
        S.get "/xpub/:xpub/unspent" $ scottyXpubUnspents net
        S.get "/xpub/:xpub" $ scottyXpubSummary net
        S.post "/transactions" $ scottyPostTx net st pub
        S.get "/dbstats" $ scottyDbStats
        S.get "/events" $ scottyEvents net pub
        S.get "/peers" $ scottyPeers net st
        S.get "/health" $ scottyHealth net st
        notFound $ raise ThingNotFound

parseLimits :: (ScottyError e, Monad m) => ActionT e m (Maybe Word32, StartFrom)
parseLimits = do
    let b = do
            height <- param "height"
            pos <- param "pos" `rescue` const (return maxBound)
            return $ StartBlock height pos
        m = do
            time <- param "time"
            return $ StartMem time
        o = do
            o <- param "offset" `rescue` const (return 0)
            return $ StartOffset o
    l <- (Just <$> param "limit") `rescue` const (return Nothing)
    s <- b <|> m <|> o
    return (l, s)

parseAddress net = do
    address <- param "address"
    case stringToAddr net address of
        Nothing -> next
        Just a  -> return a

parseAddresses net = do
    addresses <- param "addresses"
    let as = mapMaybe (stringToAddr net) addresses
    unless (length as == length addresses) next
    return as

parseXpub :: (Monad m, ScottyError e) => Network -> ActionT e m XPubKey
parseXpub net = do
    t <- param "xpub"
    case xPubImport net t of
        Nothing -> next
        Just x  -> return x

parseNoTx :: (Monad m, ScottyError e) => ActionT e m Bool
parseNoTx = param "notx" `rescue` const (return False)

pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

cors :: Monad m => ActionT e m ()
cors = setHeader "Access-Control-Allow-Origin" "*"

serialAny ::
       (JsonSerial a, BinSerial a)
    => Network
    -> Bool -- ^ binary
    -> a
    -> L.ByteString
serialAny net True  = runPutLazy . binSerial net
serialAny net False = encodingToLazyByteString . jsonSerial net

streamAny ::
       (JsonSerial i, BinSerial i, MonadIO m)
    => Network
    -> Bool -- ^ protobuf
    -> (Builder -> IO ())
    -> ConduitT i o m ()
streamAny net True io = binConduit net .| mapC lazyByteString .| streamConduit io
streamAny net False io = jsonListConduit net .| streamConduit io

jsonListConduit :: (JsonSerial a, Monad m) => Network -> ConduitT a Builder m ()
jsonListConduit net =
    yield "[" >> mapC (fromEncoding . jsonSerial net) .| intersperseC "," >> yield "]"

binConduit :: (BinSerial i, Monad m) => Network -> ConduitT i L.ByteString m ()
binConduit net = mapC (runPutLazy . binSerial net)

streamConduit :: MonadIO m => (i -> IO ()) -> ConduitT i o m ()
streamConduit io = mapM_C (liftIO . io)

setupBin :: Monad m => ActionT Except m Bool
setupBin =
    let p = do
            setHeader "Content-Type" "application/octet-stream"
            return True
        j = do
            setHeader "Content-Type" "application/json"
            return False
     in S.header "accept" >>= \case
            Nothing -> j
            Just x ->
                if is_binary x
                    then p
                    else j
  where
    is_binary = (== "application/octet-stream")

instance MonadLoggerIO m => MonadLoggerIO (WebT m) where
    askLoggerIO = lift askLoggerIO

instance MonadLogger m => MonadLogger (WebT m) where
    monadLoggerLog loc src lvl = lift . monadLoggerLog loc src lvl

healthCheck ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> Manager
    -> Chain
    -> m HealthCheck
healthCheck net mgr ch = do
    n <- timeout (5 * 1000 * 1000) $ chainGetBest ch
    b <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            MaybeT $ getBlock h
    p <- timeout (5 * 1000 * 1000) $ managerGetPeers mgr
    let k = isNothing n || isNothing b || maybe False (not . null) p
        s =
            isJust $ do
                x <- n
                y <- b
                guard $ nodeHeight x - blockDataHeight y <= 1
    return
        HealthCheck
            { healthBlockBest = headerHash . blockDataHeader <$> b
            , healthBlockHeight = blockDataHeight <$> b
            , healthHeaderBest = headerHash . nodeHeader <$> n
            , healthHeaderHeight = nodeHeight <$> n
            , healthPeers = length <$> p
            , healthNetwork = getNetworkName net
            , healthOK = k
            , healthSynced = s
            }

-- | Obtain information about connected peers from peer manager process.
getPeersInformation :: MonadIO m => Manager -> m [PeerInformation]
getPeersInformation mgr = mapMaybe toInfo <$> managerGetPeers mgr
  where
    toInfo op = do
        ver <- onlinePeerVersion op
        let as = onlinePeerAddress op
            ua = getVarString $ userAgent ver
            vs = version ver
            sv = services ver
            rl = relay ver
        return
            PeerInformation
                { peerUserAgent = ua
                , peerAddress = as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

xpubBals ::
       (MonadResource m, MonadUnliftIO m, StoreRead m) => XPubKey -> m [XPubBal]
xpubBals xpub = do
    (rk, ss) <- allocate (newTVarIO []) (\as -> readTVarIO as >>= mapM_ cancel)
    stp0 <- newTVarIO False
    stp1 <- newTVarIO False
    q0 <- newTBQueueIO 20
    q1 <- newTBQueueIO 20
    xs <-
        withAsync (go stp0 ss q0 0) $ \_ ->
            withAsync (go stp1 ss q1 1) $ \_ ->
                withAsync (red ss stp0 q0) $ \r0 ->
                    withAsync (red ss stp1 q1) $ \r1 -> do
                        xs0 <- wait r0
                        xs1 <- wait r1
                        return $ xs0 <> xs1
    release rk
    return xs
  where
    stp e =
        readTVarIO e >>= \s ->
            if s
                then return ()
                else await >>= \case
                         Nothing -> return ()
                         Just x -> yield x >> stp e
    go e ss q m =
        runConduit $
        yieldMany (as m) .| stp e .| mapMC (uncurry (b ss)) .| conduitToQueue q
    red ss e q = runConduit $ queueToConduit q .| f ss e 0 .| sinkList
    b ss a p = mask_ $ do
        s <-
            async $
            getBalance a >>= \case
                Nothing -> return Nothing
                Just b' -> return $ Just XPubBal {xPubBalPath = p, xPubBal = b'}
        atomically $ modifyTVar ss (s :)
        return s
    as m = map (\(a, _, n') -> (a, [m, n'])) (deriveAddrs (pubSubKey xpub m) 0)
    f ss e n
        | n < 20 =
            await >>= \case
                Just a ->
                    wait a >>= \case
                        Nothing -> f ss e (n + 1)
                        Just b -> yield b >> f ss e 0
                Nothing -> return ()
        | otherwise = do
            atomically $ writeTVar e True
            await >>= \case
                Just a -> do
                    cancel a
                    atomically $ modifyTVar ss (Data.List.delete a)
                    f ss e n
                Nothing -> return ()

xpubUnspent ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Network
    -> Maybe BlockRef
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspent net mbr xpub = do
    (_, as) <-
        lift $ allocate (newTVarIO []) (\as -> readTVarIO as >>= mapM_ cancel)
    xs <-
        lift $ do
            bals <- xpubBals xpub
            forM bals $ \XPubBal {xPubBalPath = p, xPubBal = b} ->
                mask_ $ do
                    q <- newTBQueueIO 10
                    a <-
                        async . runConduit $
                        getAddressUnspents (balanceAddress b) mbr .| mapC (f p) .|
                        conduitToQueue q
                    atomically $ modifyTVar as (a :)
                    return $ queueToConduit q
    mergeSourcesBy (flip compare `on` (unspentBlock . xPubUnspent)) xs
  where
    f p t = XPubUnspent {xPubUnspentPath = p, xPubUnspent = t}

xpubUnspentLimit ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Network
    -> Maybe Word32
    -> StartFrom
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspentLimit net l s x =
    xpubUnspent net (mbr s) x .| (offset s >> limit l)

xpubSummary ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> XPubKey
    -> m XPubSummary
xpubSummary l s x = do
    bs <- xpubBals x
    let f XPubBal {xPubBalPath = p, xPubBal = Balance {balanceAddress = a}} =
            (a, p)
        pm = H.fromList $ map f bs
    txs <-
        runConduit $
        getAddressesTxsFull l s (map (balanceAddress . xPubBal) bs) .| sinkList
    let as =
            nub
                [ a
                | t <- txs
                , let is = transactionInputs t
                , let os = transactionOutputs t
                , let ais =
                          mapMaybe
                              (eitherToMaybe . scriptToAddressBS . inputPkScript)
                              is
                , let aos =
                          mapMaybe
                              (eitherToMaybe . scriptToAddressBS . outputScript)
                              os
                , a <- ais ++ aos
                ]
        ps = H.fromList $ mapMaybe (\a -> (a, ) <$> H.lookup a pm) as
        ex = foldl max 0 [i | XPubBal {xPubBalPath = [x, i]} <- bs, x == 0]
        ch = foldl max 0 [i | XPubBal {xPubBalPath = [x, i]} <- bs, x == 1]
    return
        XPubSummary
            { xPubSummaryReceived =
                  sum (map (balanceTotalReceived . xPubBal) bs)
            , xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs)
            , xPubSummaryZero = sum (map (balanceZero . xPubBal) bs)
            , xPubSummaryPaths = ps
            , xPubSummaryTxs = txs
            , xPubChangeIndex = ch
            , xPubExternalIndex = ex
            }

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreRead m)
    => Int -- ^ how many ancestors to test before giving up
    -> BlockHeight
    -> TxHash
    -> m TxAfterHeight
cbAfterHeight d h t
    | d <= 0 = return $ TxAfterHeight Nothing
    | otherwise = do
        x <- fmap snd <$> tst d t
        return $ TxAfterHeight x
  where
    tst e x
        | e <= 0 = return Nothing
        | otherwise = do
            let e' = e - 1
            getTransaction x >>= \case
                Nothing -> return Nothing
                Just tx ->
                    if any isCoinbase (transactionInputs tx)
                        then return $
                             Just (e', blockRefHeight (transactionBlock tx) > h)
                        else case transactionBlock tx of
                                 BlockRef {blockRefHeight = b}
                                     | b <= h -> return $ Just (e', False)
                                 _ ->
                                     r e' . nub $
                                     map
                                         (outPointHash . inputPoint)
                                         (transactionInputs tx)
    r e [] = return $ Just (e, False)
    r e (n:ns) =
        tst e n >>= \case
            Nothing -> return Nothing
            Just (e', s) ->
                if s
                    then return $ Just (e', True)
                    else r e' ns

-- Snatched from:
-- https://github.com/cblp/conduit-merge/blob/master/src/Data/Conduit/Merge.hs
mergeSourcesBy ::
       (Foldable f, Monad m)
    => (a -> a -> Ordering)
    -> f (ConduitT () a m ())
    -> ConduitT i a m ()
mergeSourcesBy f = mergeSealed . fmap sealConduitT . toList
  where
    mergeSealed sources = do
        prefetchedSources <- lift $ traverse ($$++ await) sources
        go [(a, s) | (s, Just a) <- prefetchedSources]
    go [] = pure ()
    go sources = do
        let (a, src1):sources1 = sortBy (f `on` fst) sources
        yield a
        (src2, mb) <- lift $ src1 $$++ await
        let sources2 =
                case mb of
                    Nothing -> sources1
                    Just b  -> (b, src2) : sources1
        go sources2

getMempoolLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> ConduitT () TxHash m ()
getMempoolLimit _ StartBlock {} = return ()
getMempoolLimit l (StartMem t) =
    getMempool (Just t) .| mapC snd .| limit l
getMempoolLimit l s =
    getMempool Nothing .| mapC snd .| (offset s >> limit l)

getAddressTxsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () BlockTx m ()
getAddressTxsLimit l s a =
    getAddressTxs a (mbr s) .| (offset s >> limit l)

getAddressTxsFull ::
       (Monad m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () Transaction m ()
getAddressTxsFull l s a =
    getAddressTxsLimit l s a .| concatMapMC (getTransaction . blockTxHash)

getAddressesTxsLimit ::
       (MonadResource m, MonadUnliftIO m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () BlockTx m ()
getAddressesTxsLimit l s addrs = do
    (_, ss) <-
        lift $ allocate (newTVarIO []) (\ss -> readTVarIO ss >>= mapM_ cancel)
    xs <-
        lift $ do
            forM addrs $ \addr -> mask_ $ do
                q <- newTBQueueIO 10
                a <-
                    async . runConduit $
                    getAddressTxs addr (mbr s) .| conduitToQueue q
                atomically $ modifyTVar ss (a :)
                return $ queueToConduit q
    mergeSourcesBy (flip compare `on` blockTxBlock) xs .| dedup .|
        (offset s >> limit l)

getAddressesTxsFull ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () Transaction m ()
getAddressesTxsFull l s as =
    getAddressesTxsLimit l s as .| concatMapMC (getTransaction . blockTxHash)

getAddressUnspentsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () Unspent m ()
getAddressUnspentsLimit l s a =
    getAddressUnspents a (mbr s) .| (offset s >> limit l)

getAddressesUnspentsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () Unspent m ()
getAddressesUnspentsLimit l s as =
    mergeSourcesBy
        (flip compare `on` unspentBlock)
        (map (`getAddressUnspents` mbr s) as) .|
    (offset s >> limit l)

offset :: Monad m => StartFrom -> ConduitT i i m ()
offset (StartOffset o) = dropC (fromIntegral o)
offset _               = return ()

limit :: Monad m => Maybe Word32 -> ConduitT i i m ()
limit Nothing  = mapC id
limit (Just n) = takeC (fromIntegral n)

mbr :: StartFrom -> Maybe BlockRef
mbr (StartBlock h p) = Just (BlockRef h p)
mbr (StartMem t)     = Just (MemRef t)
mbr (StartOffset _)  = Nothing

conduitToQueue :: MonadIO m => TBQueue (Maybe a) -> ConduitT a Void m ()
conduitToQueue q =
    await >>= \case
        Just x -> atomically (writeTBQueue q (Just x)) >> conduitToQueue q
        Nothing -> atomically $ writeTBQueue q Nothing

queueToConduit :: MonadIO m => TBQueue (Maybe a) -> ConduitT () a m ()
queueToConduit q =
    atomically (readTBQueue q) >>= \case
        Just x -> yield x >> queueToConduit q
        Nothing -> return ()

dedup :: (Eq i, Monad m) => ConduitT i i m ()
dedup =
    let dd Nothing =
            await >>= \case
                Just x -> do
                    yield x
                    dd (Just x)
                Nothing -> return ()
        dd (Just x) =
            await >>= \case
                Just y
                    | x == y -> dd (Just x)
                    | otherwise -> do
                        yield y
                        dd (Just y)
                Nothing -> return ()
      in dd Nothing

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> Publisher StoreEvent
    -> Store
    -> Tx
    -> m (Either PubExcept ())
publishTx net pub st tx = do
    e <-
        withSubscription pub $ \s ->
            getTransaction (txHash tx) >>= \case
                Just _ -> do
                    return $ Right ()
                Nothing -> go s
    return e
  where
    go s = do
        managerGetPeers (storeManager st) >>= \case
            [] -> do
                return $ Left PubNoPeers
            OnlinePeer {onlinePeerMailbox = p, onlinePeerAddress = a}:_ -> do
                MTx tx `sendMessage` p
                let t =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                sendMessage
                    (MGetData (GetData [InvVector t (getTxHash (txHash tx))]))
                    p
                f p s
    t = 15 * 1000 * 1000
    f p s = do
        liftIO (timeout t (g p s)) >>= \case
            Nothing -> do
                return $ Left PubTimeout
            Just (Left e) -> do
                return $ Left e
            Just (Right ()) -> do
                return $ Right ()
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> return . Left $ PubReject c
            StorePeerDisconnected p' _
                | p == p' -> return $ Left PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return $ Right ()
            _ -> g p s
