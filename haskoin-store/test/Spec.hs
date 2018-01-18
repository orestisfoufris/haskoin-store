{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Maybe
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Store
import           Network.Haskoin.Transaction
import           System.IO.Temp
import           Test.Hspec

main :: IO ()
main = do
    setTestnet
    hspec $ do
        describe "bootstrap" $
            it "successfully starts actors and communicates" $
            withTestStore $ \(b, _c, _e) -> do
                _ <- blockGetBest b
                return ()
        describe "download" $ do
            it "gets 8 blocks" $
                withTestStore $ \(_b, c, e) -> do
                    bs <-
                        replicateM 9 $ do
                            BlockEvent (BestBlock b) <- receive e
                            return b
                    withAsync (dummyEventHandler e) $ \_ -> do
                        let bestHash = last bs
                        bestNodeM <- chainGetBlock bestHash c
                        bestNodeM `shouldSatisfy` isJust
                        let bestNode = fromJust bestNodeM
                            bestHeight = nodeHeight bestNode
                        bestHeight `shouldBe` 8
            it "get a block and its transactions" $
                withTestStore $ \(b, _c, e) -> do
                    bs <-
                        replicateM 382 $ do
                            BlockEvent (BestBlock bb) <- receive e
                            return bb
                    withAsync (dummyEventHandler e) $ \_ -> do
                        let blockHash = last bs
                        m <- blockGet blockHash b
                        let BlockValue {..} =
                                fromMaybe (error "Could not get block") m
                        blockValueHeight `shouldBe` 381
                        length blockValueTxs `shouldBe` 2
                        let h1 =
                                "e8588129e146eeb0aa7abdc3590f8c5920cc5ff42daf05c23b29d4ae5b51fc22"
                            h2 =
                                "7e621eeb02874ab039a8566fd36f4591e65eca65313875221842c53de6907d6c"
                        head blockValueTxs `shouldBe` h1
                        last blockValueTxs `shouldBe` h2
                        t1 <- blockGetTx h1 b
                        t1 `shouldSatisfy` isJust
                        txHash (detailedTx (fromJust t1)) `shouldBe` h1
                        t2 <- blockGetTx h2 b
                        t2 `shouldSatisfy` isJust
                        txHash (detailedTx (fromJust t2)) `shouldBe` h2

dummyEventHandler :: (MonadIO m, Mailbox b) => b a -> m ()
dummyEventHandler = forever . void . receive

withTestStore :: ((BlockStore, Chain, Inbox StoreEvent) -> IO ()) -> IO ()
withTestStore f =
    withSystemTempDirectory "haskoin-store-test-" $ \w ->
        runNoLoggingT $ do
            s <- Inbox <$> liftIO newTQueueIO
            c <- Inbox <$> liftIO newTQueueIO
            b <- Inbox <$> liftIO newTQueueIO
            e <- Inbox <$> liftIO newTQueueIO
            let cfg =
                    StoreConfig
                    { storeConfDir = w
                    , storeConfBlocks = b
                    , storeConfSupervisor = s
                    , storeConfChain = c
                    , storeConfListener = (`sendSTM` e)
                    , storeConfMaxPeers = 20
                    , storeConfInitPeers = []
                    , storeConfNoNewPeers = False
                    , storeConfCacheNo = 100000
                    , storeConfBlockNo = 200
                    }
            withAsync (store cfg) $ \a -> do
                link a
                x <- liftIO $ f (b, c, e)
                stopSupervisor s
                wait a
                return x
