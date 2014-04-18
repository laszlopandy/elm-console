module IO.Runner where

import Automaton as Auto
import Either (..)
import Trampoline
    
import IO.IO as IO
import IO.IO (IO)

type Request  = { mPut  : Maybe String
                , mExit : Maybe Int
                , mGet  : Bool
                }

type Response = Maybe String
type IOState  = { buffer : String }

orSig : Signal a -> Signal b -> Signal (Either a b)
orSig s1 s2 = merge (Left <~ s1) (Right <~ s2)

start : IOState 
start = { buffer = "" }

-- | We send a batch job of requests, all requests until IO blocks
-- | This removes the need for a pumping signal
run : Signal Response -> IO () -> Signal [Request]
run resps io = Auto.run (Auto.hiddenState (io, start) step) [] resps

empty : Request
empty = { mPut = Nothing, mExit = Nothing, mGet = False }

putS : String -> Request
putS s = { empty | mPut <- Just s }

exit : Int -> Request
exit n = { empty | mExit <- Just n }

getS : Request
getS = { empty | mGet <- True }

-- | Extract all of the requests that can be run now
extractRequests : IO a -> State IOState ([Request], IO a)
extractRequests io = 
  case io of
    IO.Pure x -> pure ([exit 0], IO.Pure x)
    IO.Impure iof -> case iof of
      IO.PutS s k -> extractRequests k >>= \(rs, k') ->
                     pure (flattenReqs (putS s) rs, k')
      IO.Exit n   -> pure ([exit n], io)
      IO.GetC k   ->
        ask >>= \st ->
        case String.uncons st.buffer of
          Nothing -> pure ([getS], io)
          Just (c, rest) ->
            put ({ buffer = rest }) >>= \_ ->
            extractRequests (k c)

flattenReqs : Request -> [Request] -> [Request]
flattenReqs r rs =
    let loop r rs n = 
            case r.mExit of
              Just n -> Trampoline.Done [r]
              _ ->
                  case (r.mPut, rs) of
                    (Just s1, r2 :: rs') ->
                        case r2.mPut of
                          Just s2 ->
                              let newS = s1 ++ s2
                              in if n >= 100
                                 then Trampoline.Continue (\_ -> loop (putS newS) rs' 0)
                                 else loop (putS newS) rs' (n + 1)
                          _ -> Trampoline.Done (r :: rs)
                    _ -> Trampoline.Done (r :: rs)
    in Trampoline.trampoline <| loop r rs 0
                         
step : Response -> (IO a, IOState) -> ((IO a, IOState), [Request])
step resp (io, st) = 
  let newST = case resp of 
        Nothing -> st
        Just s  -> { st | buffer <- String.append st.buffer s }
      (newST', (rs, k)) = extractRequests io newST
  in ((k, newST'), rs)

-- | State monad
type State s a = s -> (s, a)

pure : a -> State s a
pure x = \s -> (s, x)

(>>=) : State s a -> (a -> State s b) -> State s b
f >>= k = \s -> let (s', y) = f s
                in k y s'

ask : State s s
ask = \s -> (s, s)

put : s -> State s ()
put s = \_ -> (s, ())