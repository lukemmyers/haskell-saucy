 {-# LANGUAGE ImplicitParams, ScopedTypeVariables, RankNTypes,
              PartialTypeSignatures,
      FlexibleInstances, FlexibleContexts, UndecidableInstances
  #-}

module Commitment where

import Control.Concurrent.MonadIO
import Data.IORef.MonadIO
import Data.Map.Strict (member, empty, insert, Map)
import qualified Data.Map.Strict as Map
import Control.Monad (forever)
import Control.Monad.Trans.Reader
import ProcessIO
import StaticCorruptions


data Void


--
fTwoWay :: MonadFunctionality m => Functionality a a Void Void Void Void m
fTwoWay (p2f, f2p) _ _ = do
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read (snd ?sid)
  forever $ do
    (pid, m) <- readChan p2f
    case () of _ | pid == pidS -> writeChan f2p (pidR, m)
                 | pid == pidR -> writeChan f2p (pidS, m)

-- Commitment is impossible to realize in the standard model

data ComP2F a = ComP2F_Commit a | ComP2F_Open deriving Show
data ComF2P a = ComF2P_OK | ComF2P_Commit   | ComF2P_Open a deriving Show

fComDbg :: MonadFunctionality m => (Chan a) -> Functionality (ComP2F a) (ComF2P a) Void Void Void Void m
fComDbg dbg = fCom_ (Just dbg)
fCom :: MonadFunctionality m => Functionality (ComP2F a) (ComF2P a) Void Void Void Void m
fCom = fCom_ Nothing -- Without debug

fCom_ :: MonadFunctionality m => Maybe (Chan a) -> Functionality (ComP2F a) (ComF2P a) Void Void Void Void m
fCom_ dbg (p2f, f2p) (a2f, f2a) (z2f, f2z) = do
  -- Parse sid as defining two players
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read (snd ?sid)

  s2f <- newChan
  fork $ forever $ do
    (pid, m) <- readChan p2f
    case () of _ | pid == pidS -> writeChan s2f m

  -- Receive a value from the sender
  ~(ComP2F_Commit x) <- readChan s2f
  -- Debug option:
  case dbg of
    Just d -> writeChan d x
    Nothing -> do
      writeChan f2p (pidR, ComF2P_Commit)

      -- Receive the opening instruction from the sender
      ~(ComP2F_Open) <- readChan s2f
      writeChan f2p (pidR, ComF2P_Open x)


envComBenign z2exec (p2z, z2p) (a2z, z2a) (f2z, z2f) pump outp = do
  let sid = ("sidTestCommit", show ("Alice", "Bob", ("", "")))
  writeChan z2exec $ SttCrupt_SidCrupt sid empty

  -- Flip a random bit
  () <- readChan pump
  b <- getBit

  fork $ forever $ do
    (pid,x) <- readChan p2z
    liftIO $ putStrLn $ "Z: party [" ++ pid ++ "] recvd " -- ++ show x
    case x of
      ComF2P_Open b' | pid == "Bob" -> writeChan outp (b, b')
      ComF2P_Commit  | pid == "Bob" -> ?pass

  fork $ forever $ do
    _ <- readChan a2z
    undefined

  -- Have Alice comit to a bit
  writeChan z2p ("Alice", ComP2F_Commit b)

  -- Have Alice open the message
  () <- readChan pump
  writeChan z2p ("Alice", ComP2F_Open)

  readChan pump

      
testComBenignIdeal :: (forall m. MonadAdversary m => Adversary a b (ComF2P Bool) (ComP2F Bool) Void Void m) -> IO (Bool,Bool)
testComBenignIdeal s = runITMinIO 120 $ execUC envComBenign (idealProtocol) (fCom) (s)

test1' = testComBenignIdeal dummyAdversary


testComBenignReal :: (forall m. MonadProtocol m => Protocol (ComP2F Bool) (ComF2P Bool) p2p p2p m) -> IO (Bool, Bool)
testComBenignReal p = runITMinIO 120 $ execUC envComBenign (p) (fTwoWay) (dummyAdversary)

{- Commitment is impossible in the plain model
   (and even in a model with direct communications 
    between sender and receiver)
   Theorem 6 from 
     Universally Composable Commitments
     https://eprint.iacr.org/2001/055 

   Suppose F_com is realizable.
   Then there is a protocol p, and a simulator s (parameterized by adversary a), such that
     forall a z. execUC z p a dF ~ execUC z dP (s a) fCom 

   We will show this is impossible, by constructing a distinguisher z such that
     execUC z p dummyA fAuth ~/~ execUC z idealP s fCom

 -}

envComZ1 alice2bob bob2alice z2exec (p2z, z2p :: Chan (PID, ComP2F Bool)) (a2z, z2a) (f2z, z2f) pump outp = do
  let sid = ("sidTestCommitZ1", show ("Alice", "Bob", ("","")))
            
  -- In Z1, Alice is corrupted
  writeChan z2exec $ SttCrupt_SidCrupt sid (Map.fromList [("Alice",())])

  -- Wait for first message
  () <- readChan pump

  -- Alert when Bob receives a "Commit" message
  fork $ forever $ do
    (pid, m) <- readChan p2z
    liftIO $ putStrLn $ "Z1: party [" ++ pid ++ "] recv " -- ++ show x
    case m of
      ComF2P_Commit | pid == "Bob" -> do writeChan outp ComF2P_Commit
      _ -> do
        liftIO $ putStrLn "problem!"
        ?pass

  -- Force Z2F to be Void
  fork $ forever $ do
    (a :: Void) <- readChan f2z 
    writeChan z2f a

  -- Forward messages from honest Bob to the outside Alice
  fork $ forever $ do
    mf <- readChan a2z
    liftIO $ putStrLn "[envComZ1]: Problem1"
    case mf of
      SttCruptA2Z_P2A (pid, m) | pid == "Bob" -> do
                     liftIO $ putStrLn $ "Z1: intercepted bob2alice"
                     undefined
                     writeChan bob2alice m
      _ -> do
        liftIO $ putStrLn "Problem1"
        ?pass
      --SttCruptA2Z_F2A (Optional :: Void) -> writeChan z2a (SttCruptZ2A_A2F v)

  -- Forward messages from the "outside" Alice to the honest Bob
  fork $ forever $ do
    m <- readChan alice2bob
    liftIO $ putStrLn "Z1: providing message on behalf of Alice"
    writeChan z2a $ SttCruptZ2A_A2P ("Alice", m)

  return ()


envComZ2 :: MonadEnvironment m => Bool ->
  (forall m. MonadAdversary m => Adversary _ _ _ _ Void Void m) ->
  (forall m. MonadProtocol m => Protocol _ _ _ _ m) ->
  Environment _ _ _ _ Void Void (Bool, Bool) m
envComZ2 option s p z2exec (p2z, z2p) (a2z, z2a) (f2z, z2f) pump outp = do
  let sid = ("sidTestCommitZ2", show ("Alice", "Bob", ("", "")))
  writeChan z2exec $ SttCrupt_SidCrupt sid (Map.fromList [("Bob",())])

  alice2bob <- newChan 
  bob2alice <- newChan
  alert <- newChan

  -- Pick a random bit
  () <- readChan pump
  b <- getBit

  fork $ forever $ do
    (pid,x) <- readChan p2z
    liftIO $ putStrLn $ "Z2: party [" ++ pid ++ "] recv " -- ++ show x
    ?pass

  fork $ forever $ do
    m <- readChan a2z
    liftIO $ putStrLn $ "Z2: adv sent " ++ show "[nothing]" --m
    case m of 
      -- Forward messages from Alice2Bob to internal Z1
      SttCruptA2Z_P2A (pid, m) | pid == "Bob" -> do
                     liftIO $ putStrLn $ "Z2: corrupt Bob received msg"
                     writeChan alice2bob m
      _ -> liftIO $ putStrLn $ "???"

  if option then do
              -- Run one copy of the experiment with ideal
              --liftIO $ putStrLn $ "Z2: running ideal Z1!"
              dbg <- newChan
              fork $ do
                   -- Marker 1
                   execUC (envComZ1 alice2bob bob2alice) (idealProtocol) (fComDbg dbg) s
                   return ()
              fork $ do 
                   b' <- readChan dbg
                   writeChan outp (b, b')
  else do
    -- Run one copy of the experiment with real protocol
    -- liftIO $ putStrLn $ "Z2: running real Z1!"
    fork $ do
         -- Marker 2
         ~ComF2P_Commit <- execUC (envComZ1 alice2bob bob2alice) (p) (fTwoWay) dummyAdversary
         writeChan outp (b, b)

  -- Have Alice commit to a bit
  writeChan z2p ("Alice", ComP2F_Commit b)

  return ()


testComZ2TestIdeal :: Bool ->
  (forall m. MonadAdversary m => Adversary _ _ _ _ Void Void m) ->
  (forall m. MonadProtocol m => Protocol _ _ _ _ m) -> IO _
testComZ2TestIdeal b s p = runITMinIO 120 $ execUC (envComZ2 b s p) (idealProtocol) (fCom) s


testComZ2TestReal :: Bool ->
  (forall m. MonadAdversary m => Adversary _ _ _ _ Void Void m) ->
  (forall m. MonadProtocol m => Protocol _ _ _ _ m) -> IO _
testComZ2TestReal b s p = runITMinIO 120 $ execUC (envComZ2 b s p) (p) (fTwoWay) dummyAdversary


-- [Experiment 0]
-- This experiment must output (b,b) for any s that makes progress
expt0 = testComBenignIdeal dummyAdversary


-- [Experiment 1]
-- By assuming to the contrary that p realizes fCom, this must also make output (b,b)
expt1B = testComBenignReal protBindingNotHiding
expt1H = testComBenignReal protHiding


-- [Experiment 2]
-- This experiment is *identical* to expt1 by observational equivalence
-- Although Z2 corrupts Bob, it forwards messages from a correct execution of Bob's protocol.
-- Note that s is ignored entirely
expt2 = testComZ2TestReal False
expt2B = expt2 simBindingNotHiding protBindingNotHiding
expt2H = expt2 simHiding protHiding


-- [Experiment 3]
-- This experiment is the result of replacing the internal real Z1
-- with the internal ideal Z1. Assuming s simulates p, 
-- these are indistinguishable
expt3 = testComZ2TestReal True
expt3B = expt3 simBindingNotHiding protBindingNotHiding
expt3H = expt3 simHiding protHiding 
-- In expt3H, the b and b' in the output (b,b') are uncorrelated, since the assumption is violated by the Hiding-Not-Binding protocol


-- [Experiment 4]
-- This experiment is the ideal analogue to expt3
-- However, here (b,b') must be *uncorrelated*. This is because
-- sim is simply not given any access to b.
expt4 = testComZ2TestIdeal True
expt4B = expt4 simBindingNotHiding protBindingNotHiding
expt4H = expt4 simHiding protHiding



-- Concrete examples of a (bad) protocol and an ineffective (but type-checking) simulator

data BindingNotHiding_Msg a = BNH_Commit a | BNH_Open deriving Show
protBindingNotHiding (z2p, p2z) (f2p, p2f) = do
  -- Parse sid as defining two players
  let sid = ?sid
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read $ snd sid
  case () of 
    _ | ?pid == pidS -> do
          ~(ComP2F_Commit b) <- readChan z2p
          writeChan p2f $ BNH_Commit b
          ~ComP2F_Open <- readChan z2p
          writeChan p2f $ BNH_Open
    _ | ?pid == pidR -> do
          ~(BNH_Commit b) <- readChan f2p
          writeChan p2z ComF2P_Commit
          ~BNH_Open <- readChan f2p
          writeChan p2z $ ComF2P_Open b
  return ()


simBindingNotHiding (z2a, a2z) (p2a, a2p) (f2a, a2f) = do
  -- Parse sid as defining two players
  let sid = ?sid
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read $ snd sid

  a2s <- newChan
  f2r <- newChan
  f2s <- newChan

  fork $ forever $ do
    mf <- readChan z2a
    case mf of SttCruptZ2A_A2P (pid, m) | pid == pidS -> do
                     liftIO $ putStrLn $ "sim: sender " ++ show m
                     writeChan a2s (m :: BindingNotHiding_Msg Bool)
               SttCruptZ2A_A2P (pid, m) | pid == pidR -> do
                     undefined -- this shouldn't happen
  fork $ forever $ do
    (pid, m) <- readChan p2a
    case () of _ | pid == pidS -> writeChan f2s m
               _ | pid == pidR -> writeChan f2r m

  if member pidS ?crupt then do
      fork $ do
        -- Handle committing
        ~(BNH_Commit b) <- readChan a2s
        liftIO $ putStrLn $ "simCom: writing p2f_Commit"
        writeChan a2p (pidS, ComP2F_Commit b)

        -- Handle opening
        ~(BNH_Open) <- readChan a2s
        writeChan a2p (pidS, ComP2F_Open)
      return ()
  else return ()

  if member pidR ?crupt then do
      fork $ do
        -- Handle delivery of commitment
        ~ComF2P_Commit <- readChan f2r
        liftIO $ putStrLn $ "simCom: received Commit"
        -- Poor simulation (it's always 0)
        writeChan a2z $ SttCruptA2Z_P2A (pidR, BNH_Commit False)
        -- Handle delivery of opening
        ~(ComF2P_Open b') <- readChan f2r
        writeChan a2z $ SttCruptA2Z_P2A (pidR, BNH_Open)
      return ()
  else return ()
  return ()


data Hiding_Msg a = Hiding_Commit | Hiding_Open a deriving Show
protHiding (z2p, p2z) (f2p, p2f) = do
  -- Parse sid as defining two players
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read $ snd ?sid
  case () of 
    _ | ?pid == pidS -> do
            ~(ComP2F_Commit b) <- readChan z2p
            writeChan p2f $ Hiding_Commit
            ~ComP2F_Open <- readChan z2p
            writeChan p2f $ Hiding_Open b
    _ | ?pid == pidR -> do
            ~Hiding_Commit <- readChan f2p
            writeChan p2z ComF2P_Commit
            ~(Hiding_Open b) <- readChan f2p
            writeChan p2z $ ComF2P_Open b          
  return ()


simHiding (z2a, a2z) (p2a, a2p) (f2a, a2f) = do
  -- Parse sid as defining two players
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read $ snd ?sid

  a2s <- newChan
  f2r <- newChan
  f2s <- newChan

  fork $ forever $ do
    mf <- readChan z2a
    case mf of SttCruptZ2A_A2P (pid, m) | pid == pidS -> do
                     liftIO $ putStrLn $ "sim: sender " ++ show m
                     writeChan a2s (m :: Hiding_Msg Bool)

  fork $ forever $ do
    (pid, m) <- readChan p2a
    case () of _ | pid == pidS -> writeChan f2s m
               _ | pid == pidR -> writeChan f2r m

  if member pidS ?crupt then do
      fork $ do
        -- Handle committing
        ~Hiding_Commit <- readChan a2s
        -- Can't simulate very well - generate a random bit
        b <- getBit
        liftIO $ putStrLn $ "sim: writing p2f_Commit"
        writeChan a2p (pidS, ComP2F_Commit b)

        -- Handle opening
        ~(Hiding_Open b') <- readChan a2s
        writeChan a2p (pidS, ComP2F_Open)
      return ()
  else return ()
  if member pidR ?crupt then do
      fork $ do
        -- Handle delivery of commitment
        ~ComF2P_Commit <- readChan f2r
        liftIO $ putStrLn $ "simCom: received Commit"
        -- Easy to simulate
        writeChan a2z $ SttCruptA2Z_P2A (pidR, Hiding_Commit)
        -- Handle delivery of opening
        ~(ComF2P_Open b) <- readChan f2r
        writeChan a2z $ SttCruptA2Z_P2A (pidR, Hiding_Open b)
      return ()
  else return ()
  return ()

{-----------------------------------------}
{- Positive result: Commitments
   in the random oracle model            -}
{-----------------------------------------}

data RoP2F a b   = RoP2F_Ro a | RoP2F_m b
data RoF2P   b   = RoF2P_Ro Int | RoF2P_m b
fTwoWayAndRO :: (Show a, MonadFunctionality m) => Functionality (RoP2F a b) (RoF2P b) Void Void Void Void m
fTwoWayAndRO (p2f, f2p) _ _ = do
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read (snd ?sid)
  table <- newIORef Map.empty
  forever $ do
    (pid, mf) <- readChan p2f
    case mf of
      RoP2F_m m | pid == pidS -> writeChan f2p (pidR, RoF2P_m m)
                | pid == pidR -> writeChan f2p (pidS, RoF2P_m m)
      RoP2F_Ro m -> do
        tbl <- readIORef table
        if member (show m) tbl then do
          let Just h = Map.lookup (show m) tbl in
            writeChan f2p (pid, RoF2P_Ro h)
          else do
          h <- getNbits 120 -- generate a random string
          modifyIORef table (Map.insert (show m) h)
          writeChan f2p (pid, RoF2P_Ro h)


data ProtComm_Msg a = ProtComm_Commit Int | ProtComm_Open Int a deriving Show
protComm (z2p, p2z) (f2p, p2f) = do
    -- Parse sid as defining two players
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read $ snd ?sid
  case () of 
    _ | ?pid == pidS -> do
          -- Wait for commit instruction
          ~(ComP2F_Commit b) <- readChan z2p
          -- Generate the blinding
          ~(nonce :: Int) <- getNbits 120
          -- Query the random oracle
          writeChan p2f $ RoP2F_Ro (nonce, b)
          ~(RoF2P_Ro h) <- readChan f2p
          writeChan p2f $ RoP2F_m (ProtComm_Commit h)

          -- Wait for open instruction
          ~ComP2F_Open <- readChan z2p
          writeChan p2f $ RoP2F_m (ProtComm_Open nonce b)

    _ | ?pid == pidR -> do
          ~(RoF2P_m (ProtComm_Commit h)) <- readChan f2p
          writeChan p2z ComF2P_Commit
          ~(RoF2P_m (ProtComm_Open nonce b)) <- readChan f2p
          -- Query the RO 
          writeChan p2f $ RoP2F_Ro (nonce, b)
          ~(RoF2P_Ro h') <- readChan f2p
          if not (h' == h) then fail "hash mismatch" else return ()

          -- Output
          writeChan p2z $ ComF2P_Open b
{--
simComm (z2a, a2z) (p2a, a2p) (f2a, a2f) = do
  -- Parse sid as defining two players
  let (pidS :: PID, pidR :: PID, ssid :: SID) = read $ snd ?sid

  a2s <- newChan
  f2r <- newChan
  f2s <- newChan

  fork $ forever $ do
    mf <- readChan z2a
    case mf of SttCruptZ2A_A2P (pid, m) | pid == pidS -> do
                     liftIO $ putStrLn $ "sim: sender " -- ++ show m
                     writeChan a2s m
  fork $ forever $ do
    (pid, m) <- readChan p2a
    case () of _ | pid == pidS -> writeChan f2s m
               _ | pid == pidR -> writeChan f2r m

  -- Internalize the RO!
  table <- newIORef Map.empty -- map x to h(x) 
  backtable <- newIORef Map.empty -- map h(x) to x

  if member pidS ?crupt then do
      fork $ do

        -- Handle committing
        RoF2P_m _ <- readChan a2s
        -- Can't simulate very well - generate a random bit
        b <- getBit
        liftIO $ putStrLn $ "sim: writing p2f_Commit"
        writeChan a2p (pidS, ComP2F_Commit b)

        -- Handle opening
        RoF2P_m _ <- readChan a2s
        writeChan a2p (pidS, ComP2F_Open)
      return ()
  else return ()
  if member pidR ?crupt then do
      fork $ do
        -- Handle delivery of commitment
        ComF2P_Commit <- readChan f2r
        liftIO $ putStrLn $ "simCom: received Commit"
        -- Easy to simulate
        writeChan a2z $ SttCruptA2Z_P2A (pidR, RoF2P_m $ ProtComm_Commit undefined)
        -- Handle delivery of opening
        ComF2P_Open b <- readChan f2r
        writeChan a2z $ SttCruptA2Z_P2A (pidR, RoF2P_m $ ProtComm_Open undefined b)
      return ()
  else return ()
  return ()

--}
testComBenignRoReal :: IO _
testComBenignRoReal = runITMinIO 120 $ execUC envComBenign (protComm) (fTwoWayAndRO) (dummyAdversary)

{--
testComBenignRoIdeal :: IO _
testComBenignRoIdeal = runITMinIO 120 $ execUC envComBenign (idealProtocol) (fCom) simComm

testComZ2RoReal :: IO _
testComZ2RoReal = runITMinIO 120 $ execUC  (envComZ2 False simComm protComm) (protComm) (fTwoWayAndRO) (dummyAdversary)

--testComZ2RoIdeal :: IO _
--testComZ2RoIdeal = runRand $ execUC (envComZ2 False simComm protComm) (idealProtocol) (runOptLeak fCom) simComm
--}
