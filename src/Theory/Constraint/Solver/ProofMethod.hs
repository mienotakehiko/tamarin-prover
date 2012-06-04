{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections   #-}
{-# LANGUAGE ViewPatterns    #-}
-- |
-- Copyright   : (c) 2010-2012 Simon Meier & Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- Proof methods and heuristics: the external small-step interface to the
-- constraint solver.
module Theory.Constraint.Solver.ProofMethod (
  -- * Proof methods
    CaseName
  , ProofMethod(..)
  , execProofMethod

  -- ** Heuristics
  , GoalRanking(..)
  , goalRankingName
  , rankProofMethods

  , Heuristic
  , roundRobinHeuristic
  , useHeuristic

  -- ** Pretty Printing
  , prettyProofMethod

) where

import           Data.Binary
import           Data.DeriveTH
import           Data.Function                             (on)
import           Data.Label                                hiding (get)
import qualified Data.Label                                as L
import           Data.List
import qualified Data.Map                                  as M
import           Data.Monoid
import           Data.Ord                                  (comparing)
import qualified Data.Set                                  as S
import           Extension.Prelude                         (sortOn)

import           Control.Basics
import           Control.DeepSeq
import           Control.Monad.Bind
import qualified Control.Monad.Trans.PreciseFresh          as Precise

import           Theory.Constraint.Solver.CaseDistinctions
import           Theory.Constraint.Solver.Contradictions
import           Theory.Constraint.Solver.Goals
import           Theory.Constraint.Solver.Reduction
import           Theory.Constraint.Solver.Simplify
import           Theory.Constraint.Solver.Types
import           Theory.Constraint.System
import           Theory.Model
import           Theory.Text.Pretty


------------------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------------------

-- | @uniqueListBy eq changes xs@ zips the @changes@ with all sequences equal
-- elements in the list.
--
-- > uniqueListBy compare id (const [ (++ show i) | i <- [1..] ]) ["a","b","a"] =
-- > ["a1","b","a2"]
--
uniqueListBy :: (a -> a -> Ordering) -> (a -> a) -> (Int -> [a -> a]) -> [a] -> [a]
uniqueListBy ord single distinguish xs0 =
      map fst
    $ sortBy (comparing snd)
    $ concat $ map uniquify $ groupBy (\x y -> ord (fst x) (fst y) == EQ)
    $ sortBy (ord `on` fst)
    $ zip xs0 [(0::Int)..]
  where
    uniquify []      = error "impossible"
    uniquify [(x,i)] = [(single x, i)]
    uniquify xs      = zipWith (\f (x,i) -> (f x, i)) dist xs
      where
        dist = distinguish $ length xs


------------------------------------------------------------------------------
-- Proof Methods
------------------------------------------------------------------------------

-- | Every case in a proof is uniquely named.
type CaseName = String

-- | Sound transformations of sequents.
data ProofMethod =
    Sorry String                         -- ^ Proof was not completed
  | Solved                               -- ^ An attack was fond
  | Simplify                             -- ^ A simplification step.
  | SolveGoal Goal                       -- ^ A goal that was solved.
  | Contradiction (Maybe Contradiction)  -- ^ A contradiction could be
                                         -- derived, possibly with a reason.
  | Induction                            -- ^ Use inductive strengthening on
                                         -- the single formula constraint in
                                         -- the system.
  deriving( Eq, Ord, Show )

instance HasFrees ProofMethod where
    foldFrees f (SolveGoal g)     = foldFrees f g
    foldFrees f (Contradiction c) = foldFrees f c
    foldFrees _ _                 = mempty

    mapFrees f (SolveGoal g)     = SolveGoal <$> mapFrees f g
    mapFrees f (Contradiction c) = Contradiction <$> mapFrees f c
    mapFrees _ method            = pure method


-- Proof method execution
-------------------------


-- @execMethod rules method se@ checks first if the @method@ is applicable to
-- the sequent @se@. Then, it applies the @method@ to the sequent under the
-- assumption that the @rules@ describe all rewriting rules in scope.
--
-- NOTE that the returned systems have their free substitution fully applied
-- and all variable indices reset.
execProofMethod :: ProofContext
                -> ProofMethod -> System -> Maybe (M.Map CaseName System)
execProofMethod ctxt method sys =
    M.map cleanupSystem <$>
      case method of
        Sorry _                  -> return M.empty
        Solved
          | null (openGoals sys) -> return M.empty
          | otherwise            -> Nothing
        SolveGoal goal           -> execSolveGoal goal
        Simplify                 -> singleCase (/=) simplifySystem
        Induction                -> execInduction
        Contradiction _
          | null (contradictions ctxt sys) -> Nothing
          | otherwise                      -> Just M.empty
  where
    -- at this point it is safe to remove the free substitution, as all
    -- systems have it fully applied (by the virtue of a call to
    -- simplifySystem). We also reset the variable indices here.
    cleanupSystem =
         (`Precise.evalFresh` Precise.nothingUsed)
       . (`evalBindT` noBindings)
       . someInst
       . set sSubst emptySubst


    -- expect only one or no subcase in the given case distinction
    singleCase check m =
        case map fst $ getDisj $ execReduction m ctxt sys (avoid sys) of
          []                      -> return $ M.empty
          [sys'] | check sys sys' -> return $ M.singleton "" sys'
                 | otherwise      -> mzero
          syss                    ->
               return $ M.fromList (zip (map show [(1::Int)..]) syss)

    -- solve the given goal
    -- PRE: Goal must be valid in this system.
    execSolveGoal goal = do
        return $ makeCaseNames $ map fst $ getDisj $
            runReduction solver ctxt sys (avoid sys)
      where
        ths    = L.get pcCaseDists ctxt
        solver = do name <- maybe (solveGoal goal)
                                  (fmap $ concat . intersperse "_")
                                  (solveWithCaseDistinction ctxt ths goal)
                    simplifySystem
                    return name

        makeCaseNames =
            M.fromListWith (error "case names not unique")
          . uniqueListBy (comparing fst) id distinguish
          where
            distinguish n =
                [ (\(x,y) -> (x ++ "_case_" ++ pad (show i), y))
                | i <- [(1::Int)..] ]
              where
                l      = length (show n)
                pad cs = replicate (l - length cs) '0' ++ cs

    -- Apply induction: possible if the system contains only
    -- a single formula.
    execInduction
      | sys == sys0 =
          case S.toList $ L.get sFormulas sys of
            [gf] -> case ginduct gf of
              Right gf' -> Just $ M.singleton "induction"
                                $ set sFormulas (S.singleton gf') sys
              _         -> Nothing
            _    -> Nothing

      | otherwise = Nothing
      where
        sys0 = set sFormulas (L.get sFormulas sys)
             $ set sLemmas (L.get sLemmas sys)
             $ emptySystem (L.get sCaseDistKind sys)


------------------------------------------------------------------------------
-- Heuristics
------------------------------------------------------------------------------

-- | The different available functions to rank goals with respect to their
-- order of solving in a constraint system.
data GoalRanking =
    GoalNrRanking
  | UsefulGoalNrRanking
  | SmartRanking Bool
  deriving( Eq, Ord, Show )

-- | The name/explanation of a 'GoalRanking'.
goalRankingName :: GoalRanking -> String
goalRankingName ranking =
    "Goals sorted according to " ++ case ranking of
        GoalNrRanking                -> "their order of creation"
        UsefulGoalNrRanking          -> "their usefulness and order of creation"
        SmartRanking useLoopBreakers -> smart useLoopBreakers
   where
     smart b = "the 'smart' heuristic (loop breakers " ++
               (if b then "allowed" else "delayed") ++ ")."

-- | Use a 'GoalRanking' to sort a list of 'AnnotatedGoal's stemming from the
-- given constraint 'System'.
rankGoals :: GoalRanking -> System -> [AnnotatedGoal] -> [AnnotatedGoal]
rankGoals ranking = case ranking of
    GoalNrRanking       -> \_sys -> goalNrRanking
    UsefulGoalNrRanking ->
        \_sys -> sortOn (\(_, (nr, useless)) -> (useless, nr))
    SmartRanking useLoopsBreakers -> smartRanking useLoopsBreakers

-- | Use a 'GoalRanking' to generate the ranked, list of possible
-- 'ProofMethod's and their corresponding results in this 'ProofContext' and
-- for this 'System'. If the resulting list is empty, then the constraint
-- system is solved.
rankProofMethods :: GoalRanking -> ProofContext -> System
                 -> [(ProofMethod, (M.Map CaseName System, String))]
rankProofMethods ranking ctxt sys = do
    (m, expl) <-
            (contradiction <$> contradictions ctxt sys)
        <|> (case L.get pcUseInduction ctxt of
               AvoidInduction -> [(Simplify, ""), (Induction, "")]
               UseInduction   -> [(Induction, ""), (Simplify, "")]
            )
        <|> (solveGoalMethod <$> (rankGoals ranking sys $ openGoals sys))
    case execProofMethod ctxt m sys of
      Just cases -> return (m, (cases, expl))
      Nothing    -> []
  where
    contradiction c                    = (Contradiction (Just c), "")
    solveGoalMethod (goal, (nr, usefulness)) =
      ( SolveGoal goal
      , "nr. " ++ show nr ++ case usefulness of
                               Useful -> ""
                               Useless -> " (marked useless)"
      )

newtype Heuristic = Heuristic [GoalRanking]
    deriving( Eq, Ord, Show )

-- | Smart constructor for heuristics. Schedules the goal rankings in a
-- round-robin fashion dependent on the proof depth.
roundRobinHeuristic :: [GoalRanking] -> Heuristic
roundRobinHeuristic = Heuristic

-- | Use a heuristic to schedule a 'GoalRanking' according to the given
-- proof-depth.
useHeuristic :: Heuristic -> Int -> GoalRanking
useHeuristic (Heuristic []      ) = error "useHeuristic: empty list of rankings"
useHeuristic (Heuristic rankings) =
    ranking
  where
    n = length rankings

    ranking depth
      | depth < 0 = error $ "useHeuristic: negative proof depth " ++ show depth
      | otherwise = rankings !! (depth `mod` n)



{-
-- | Schedule the given local-heuristics in a round-robin fashion.
roundRobinHeuristic :: [GoalRanking] -> Heuristic
roundRobinHeuristic []       = error "roundRobin: empty list of rankings"
roundRobinHeuristic rankings =
    methods
  where
    n = length rankings

    methods depth ctxt sys
      | depth < 0 = error $ "roundRobin: negative proof depth " ++ show depth
      | otherwise =
          ( name
          ,     ((Contradiction . Just) <$> contradictions ctxt sys)
            <|> (case L.get pcUseInduction ctxt of
                   AvoidInduction -> [Simplify, Induction]
                   UseInduction   -> [Induction, Simplify]
                )
            <|> ((SolveGoal . fst) <$> (ranking sys $ openGoals sys))
          )
      where
        (name, ranking) = rankings !! (depth `mod` n)
-}

-- | Sort annotated goals according to their number.
goalNrRanking :: [AnnotatedGoal] -> [AnnotatedGoal]
goalNrRanking = sortOn (fst . snd)

-- | A ranking function tuned for the automatic verification of
-- classical security protocols that exhibit a well-founded protocol premise
-- fact flow.
smartRanking :: Bool   -- True if PremiseG loop-breakers should not be delayed
             -> System
             -> [AnnotatedGoal] -> [AnnotatedGoal]
smartRanking allowPremiseGLoopBreakers sys =
    delayUseless . unmark . sortDecisionTree solveFirst . goalNrRanking
  where
    delayUseless = sortOn (snd . snd)

    unmark | allowPremiseGLoopBreakers = map unmarkPremiseG
           | otherwise                 = id

    unmarkPremiseG (goal@(PremiseG _ _), (nr, _)) = (goal, (nr, Useful))
    unmarkPremiseG annGoal                        = annGoal

    solveFirst =
        [ isChainGoal . fst
        , isDisjGoal . fst
        , isNonLoopBreakerProtoFactGoal
        , isStandardActionGoal . fst
        , isFreshKnowsGoal . fst
        , isSplitGoalSmall . fst
        , isDoubleExpGoal . fst
        , isLoopBreakerGoal ]
          -- prefer knowledge goals and loop-breaker premises
          -- before expensive equation splits

    isNonLoopBreakerProtoFactGoal (PremiseG _ fa, (_, Useful)) = not $ isKFact fa
    isNonLoopBreakerProtoFactGoal _                            = False

    msgPremise (ActionG _ fa) = do (UpK, _, m) <- kFactView fa; return m
    msgPremise _              = Nothing

    isFreshKnowsGoal goal = case msgPremise goal of
        Just (viewTerm -> Lit (Var lv)) | lvarSort lv == LSortFresh -> True
        _                                                           -> False

    isDoubleExpGoal goal = case msgPremise goal of
        Just (viewTerm2 -> FExp  _ (viewTerm2 -> FMult _)) -> True
        _                                                  -> False

    isLoopBreakerGoal (ActionG _ fa, _           ) = isKUFact fa
    isLoopBreakerGoal (PremiseG _ _, (_, Useless)) = True
    isLoopBreakerGoal _                            = False

    -- Be conservative on splits that don't exist.
    isSplitGoalSmall (SplitG sid) =
        maybe False (< 3) $ splitSize (L.get sEqStore sys) sid
    isSplitGoalSmall _            = False

    -- | @sortDecisionTree xs ps@ returns a reordering of @xs@
    -- such that the sublist satisfying @ps!!0@ occurs first,
    -- then the sublist satisfying @ps!!1@, and so on.
    sortDecisionTree :: [a -> Bool] -> [a] -> [a]
    sortDecisionTree []     xs = xs
    sortDecisionTree (p:ps) xs = sat ++ sortDecisionTree ps nonsat
      where (sat, nonsat) = partition p xs



------------------------------------------------------------------------------
-- Pretty printing
------------------------------------------------------------------------------

-- | Pretty-print a proof method.
prettyProofMethod :: HighlightDocument d => ProofMethod -> d
prettyProofMethod method = case method of
    Solved               -> keyword_ "SOLVED" <-> lineComment_ "trace found"
    Induction            -> keyword_ "induction"
    Sorry reason         -> fsep [keyword_ "sorry", lineComment_ reason]
    SolveGoal goal       ->
        keyword_ "solve(" <-> prettyGoal goal <-> keyword_ ")"
    Simplify             -> keyword_ "simplify"
    Contradiction reason ->
        sep [ keyword_ "contradiction"
            , maybe emptyDoc (lineComment . prettyContradiction) reason
            ]



-- Derived instances
--------------------

$( derive makeBinary ''ProofMethod)
$( derive makeBinary ''GoalRanking)
$( derive makeBinary ''Heuristic)

$( derive makeNFData ''ProofMethod)
$( derive makeNFData ''GoalRanking)
$( derive makeNFData ''Heuristic)
