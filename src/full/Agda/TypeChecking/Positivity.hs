{-# LANGUAGE CPP #-}

-- | Check that a datatype is strictly positive.
module Agda.TypeChecking.Positivity where

import Control.Applicative hiding (empty)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map (Map)
import qualified Data.Map as Map
import Data.List as List

import Agda.Syntax.Position
import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Substitute

import Agda.Utils.Warshall hiding (Node)
import Agda.Utils.Impossible
import Agda.Utils.Permutation
import Agda.Utils.Size
import Agda.Utils.Monad

#include "../undefined.h"

checkPosArg _ _ = return ()
initPosState = error "initPosState"

-- | Check that the datatypes in the given mutual block
--   are strictly positive.
checkStrictlyPositive :: MutualId -> TCM ()
checkStrictlyPositive mi = do
  qs <- lookupMutualBlock mi
  reportSDoc "tc.pos.tick" 100 $ text "positivity of" <+> prettyTCM (Set.toList qs)
  g  <- buildOccurrenceGraph qs
  reportSDoc "tc.pos.tick" 100 $ text "constructed graph"
  let cg = warshall' g
  reportSDoc "tc.pos.graph" 10 $ vcat
    [ text "positivity graph for" <+> prettyTCM (Set.toList qs)
    , nest 2 $ prettyGraph g
    , text "completed graph"
    , nest 2 $ prettyGraph cg
    ]
  mapM_ (setArgs $ edges cg) $ Set.toList qs
  reportSDoc "tc.pos.tick" 100 $ text "completed graph"
  whenM positivityCheckEnabled $
    mapM_ (checkPos cg) $ Set.toList qs
  reportSDoc "tc.pos.tick" 100 $ text "checked positivity"
  where
    checkPos g q = whenM (isDatatype q) $ do
      reportSDoc "tc.pos.check" 10 $ text "checking positivity of" <+> prettyTCM q
      case lookupEdge (DefNode q) (DefNode q) g of
        Nothing                  -> return ()
        Just (Edge Positive _)   -> return ()
        Just (Edge Unused _)     -> return ()
        Just (Edge Negative how) -> do
          err <- fsep $
            [prettyTCM q] ++ pwords "is not strictly positive, because it occurs" ++
            [prettyTCM how]
          setCurrentRange (getRange q) $ typeError $ GenericError (show err)

    isDatatype q = do
      def <- theDef <$> getConstInfo q
      return $ case def of
        Datatype{dataClause = Nothing} -> True
        _ -> False

    -- Set the polarity of the arguments to a definition
    setArgs es q = do
      let args = expand 0 $ List.sort
                    [ (i, o) | (ArgNode q1 i, DefNode q2, Edge o _) <- es
                    , q1 == q, q2 == q ]
          expand _ [] = []
          expand i xs@((j, o):xs')
            | i < j     = Unused : expand (i + 1) xs
            | i == j    = o : expand (i + 1) xs'
            | otherwise = __IMPOSSIBLE__
      setArgOccurrences q args

    g =~= g' = order (edges g) == order (edges g')
    order xs = List.sort $ map (\(x,y,Edge o _) -> (x, y, o)) xs

    -- We need to iterate warshall since Negative edges
    -- behave as negative weights.
    warshall' g
      | g =~= g'  = g
      | otherwise = warshall' g'
      where
        g' = warshallG g

-- Specification of occurrences -------------------------------------------

instance SemiRing Occurrence where
  oplus Negative _        = Negative
  oplus _ Negative        = Negative
  oplus Unused o          = o
  oplus o Unused          = o
  oplus Positive Positive = Positive

  otimes Unused _          = Unused
  otimes _ Unused          = Unused
  otimes Negative _        = Negative
  otimes _ Negative        = Negative
  otimes Positive Positive = Positive

-- | Description of an occurrence.
data OccursWhere
  = LeftOfArrow OccursWhere
  | DefArg QName Nat OccursWhere -- ^ in the nth argument of a define constant
  | VarArg OccursWhere           -- ^ as an argument to a bound variable
  | MetaArg OccursWhere          -- ^ as an argument of a metavariable
  | ConArgType QName OccursWhere -- ^ in the type of a constructor
  | InClause Nat OccursWhere     -- ^ in the nth clause of a defined function
  | InDefOf QName OccursWhere    -- ^ in the definition of a constant
  | Here
  | Unknown                      -- ^ an unknown position (treated as negative)
  deriving (Show, Eq)

(>*<) :: OccursWhere -> OccursWhere -> OccursWhere
Here            >*< o  = o
Unknown         >*< o  = Unknown
LeftOfArrow o1  >*< o2 = LeftOfArrow (o1 >*< o2)
DefArg d i o1   >*< o2 = DefArg d i (o1 >*< o2)
VarArg o1       >*< o2 = VarArg (o1 >*< o2)
MetaArg o1      >*< o2 = MetaArg (o1 >*< o2)
ConArgType c o1 >*< o2 = ConArgType c (o1 >*< o2)
InClause i o1   >*< o2 = InClause i (o1 >*< o2)
InDefOf d o1    >*< o2 = InDefOf d (o1 >*< o2)

instance PrettyTCM OccursWhere where
  prettyTCM o = prettyOs $ map maxOneLeftOfArrow $ uniq $ splitOnDef o
    where
      nth 0 = pwords "first"
      nth 1 = pwords "second"
      nth 2 = pwords "third"
      nth n = pwords $ show (n - 1) ++ "th"

      uniq (x:y:xs)
        | x == y  = uniq (x:xs)
      uniq (x:xs) = x : uniq xs
      uniq []     = []

      prettyOs [] = __IMPOSSIBLE__
      prettyOs [o] = prettyO o
      prettyOs (o:os) = prettyO o <> text ", which occurs" <+> prettyOs os

      prettyO o = case o of
        Here           -> empty
        Unknown        -> empty
        LeftOfArrow o  -> explain o $ pwords "to the left of an arrow"
        DefArg q i o   -> explain o $ pwords "in the" ++ nth i ++ pwords "argument to" ++
                                      [prettyTCM q]
        VarArg o       -> explain o $ pwords "in an argument to a bound variable"
        MetaArg o      -> explain o $ pwords "in an argument to a metavariable"
        ConArgType c o -> explain o $ pwords "in the type of the constructor" ++ [prettyTCM c]
        InClause i o   -> explain o $ pwords "in the" ++ nth i ++ pwords "clause"
        InDefOf d o    -> explain o $ pwords "in the definition of" ++ [prettyTCM d]

      explain o ds = prettyO o $$ fsep ds

      maxOneLeftOfArrow o = case o of
        LeftOfArrow o  -> LeftOfArrow $ purgeArrows o
        Here           -> Here
        Unknown        -> Unknown
        DefArg q i o   -> DefArg q i   $ maxOneLeftOfArrow o
        InDefOf d o    -> InDefOf d    $ maxOneLeftOfArrow o
        VarArg o       -> VarArg       $ maxOneLeftOfArrow o
        MetaArg o      -> MetaArg      $ maxOneLeftOfArrow o
        ConArgType c o -> ConArgType c $ maxOneLeftOfArrow o
        InClause i o   -> InClause i   $ maxOneLeftOfArrow o

      purgeArrows o = case o of
        LeftOfArrow o -> purgeArrows o
        Here           -> Here
        Unknown        -> Unknown
        DefArg q i o   -> DefArg q i   $ purgeArrows o
        InDefOf d o    -> InDefOf d    $ purgeArrows o
        VarArg o       -> VarArg       $ purgeArrows o
        MetaArg o      -> MetaArg      $ purgeArrows o
        ConArgType c o -> ConArgType c $ purgeArrows o
        InClause i o   -> InClause i   $ purgeArrows o

      splitOnDef o = case o of
        Here           -> [Here]
        Unknown        -> [Unknown]
        InDefOf d o    -> sp (InDefOf d) o
        LeftOfArrow o  -> sp LeftOfArrow o
        DefArg q i o   -> sp (DefArg q i) o
        VarArg o       -> sp VarArg o
        MetaArg o      -> sp MetaArg o
        ConArgType c o -> sp (ConArgType c) o
        InClause i o   -> sp (InClause i) o
        where
          sp f o = case splitOnDef o of
            os@(InDefOf _ _:_) -> f Here : os
            o:os               -> f o : os
            []                 -> __IMPOSSIBLE__

-- Computing occurrences --------------------------------------------------

data Item = AnArg Nat
          | ADef QName
  deriving (Eq, Ord, Show)

type Occurrences = Map Item [OccursWhere]

(>+<) :: Occurrences -> Occurrences -> Occurrences
(>+<) = Map.unionWith (++)

concatOccurs :: [Occurrences] -> Occurrences
concatOccurs = Map.unionsWith (++)

occursAs :: (OccursWhere -> OccursWhere) -> Occurrences -> Occurrences
occursAs f = Map.map (map f)

here :: Item -> Occurrences
here i = Map.singleton i [Here]

class ComputeOccurrences a where
  -- | The first argument is the items corresponding to the free variables.
  occurrences :: [Maybe Item] -> a -> Occurrences

instance ComputeOccurrences Clause where
  occurrences vars (Clause _ _ ps body) =
    walk vars (patItems ps) body
    where
      walk _    _         NoBody     = Map.empty
      walk vars []        (Body v)   = walkLambdas (genericLength ps) vars v
      walk vars (i : pis) (Bind b)   = walk (i : vars) pis $ absBody b
      walk vars (_ : pis) (NoBind b) = walk vars pis b
      walk _    []        Bind{}     = __IMPOSSIBLE__
      walk _    []        NoBind{}   = __IMPOSSIBLE__
      walk _    (_ : _)   Body{}     = __IMPOSSIBLE__

      -- Lambdas on the top-level of the rhs can be treated as arguments
      walkLambdas i vars (Lam _ b) =
        walkLambdas (i + 1) (Just (AnArg i) : vars) (absBody b)
      walkLambdas _ vars v = occurrences vars v

      patItems ps = concat $ zipWith patItem [0..] $ map unArg ps
      patItem i (VarP _) = [Just (AnArg i)]
      patItem i p        = replicate (nVars p) Nothing

      nVars p = case p of
        VarP{}    -> 1
        DotP{}    -> 1
        ConP _ ps -> sum $ map (nVars . unArg) ps
        LitP{}    -> 0

instance ComputeOccurrences Term where
  occurrences vars v = case ignoreBlocking v of
    Var i args ->
      maybe Map.empty here (vars ! fromIntegral i)
      >+< occursAs VarArg (occurrences vars args)
    Def d args   ->
      here (ADef d) >+<
      concatOccurs (zipWith (occursAs . DefArg d) [0..] $ map (occurrences vars) args)
    Con c args   -> occurrences vars args
    MetaV _ args -> occursAs MetaArg $ occurrences vars args
    Pi a b       -> occursAs LeftOfArrow (occurrences vars a) >+<
                    occurrences vars b
    Fun a b      -> occursAs LeftOfArrow (occurrences vars a) >+<
                    occurrences vars b
    Lam _ b      -> occurrences vars b
    Lit{}        -> Map.empty
    Sort{}       -> Map.empty
    BlockedV{}   -> __IMPOSSIBLE__
    where
      vs ! i
        | i < length vs = vs !! i
        | otherwise     = error $ show vs ++ " ! " ++ show i ++ "  (" ++ show v ++ ")"

instance ComputeOccurrences Type where
  occurrences vars (El _ v) = occurrences vars v

instance ComputeOccurrences Telescope where
  occurrences vars EmptyTel        = Map.empty
  occurrences vars (ExtendTel a b) = occurrences vars (a, b)

instance ComputeOccurrences a => ComputeOccurrences (Abs a) where
  occurrences vars = occurrences (Nothing : vars) . absBody

instance ComputeOccurrences a => ComputeOccurrences (Arg a) where
  occurrences vars = occurrences vars . unArg

instance ComputeOccurrences a => ComputeOccurrences [a] where
  occurrences vars = concatOccurs . map (occurrences vars)

instance (ComputeOccurrences a, ComputeOccurrences b) => ComputeOccurrences (a, b) where
  occurrences vars (x, y) = occurrences vars x >+< occurrences vars y

-- | Compute the occurrences in a given definition.
computeOccurrences :: QName -> TCM Occurrences
computeOccurrences q = do
  def <- getConstInfo q
  occursAs (InDefOf q) <$> case theDef def of
    Function{funClauses = cs} ->
      return
        $ concatOccurs
        $ zipWith (occursAs . InClause) [0..]
        $ map (occurrences []) cs
    Datatype{dataClause = Just c} -> return $ occurrences [] c
    Datatype{dataPars = np, dataCons = cs}       -> do
      let conOcc c = do
            a <- defType <$> getConstInfo c
            TelV tel _ <- telView <$> normalise a
            let tel' = telFromList $ genericDrop np $ telToList tel
                vars = reverse [ Just (AnArg i) | i <- [0..np - 1] ]
            return $ occursAs (ConArgType c) $ occurrences vars tel'
      concatOccurs <$> mapM conOcc cs
    Record{recClause = Just c} -> return $ occurrences [] c
    Record{recPars = np, recTel = tel} -> do
      let tel' = telFromList $ genericDrop np $ telToList tel
          vars = reverse [ Just (AnArg i) | i <- [0..np - 1] ]
      return $ occurrences vars tel'

    -- Arguments to other kinds of definitions are hard-wired.
    Constructor{} -> return Map.empty
    Axiom{}       -> return Map.empty
    Primitive{}   -> return Map.empty

-- Building the occurrence graph ------------------------------------------

data Node = DefNode QName
          | ArgNode QName Nat
  deriving (Eq, Ord)

instance Show Node where
  show (DefNode q)   = show q
  show (ArgNode q i) = show q ++ "." ++ show i

instance PrettyTCM Node where
  prettyTCM (DefNode q)   = prettyTCM q
  prettyTCM (ArgNode q i) = prettyTCM q <> text ("." ++ show i)

prettyGraph g = vcat $ map pr $ Map.assocs g
  where
    pr (n, es) = sep
      [ prettyTCM n
      , nest 2 $ vcat $ map prE es
      ]
    prE (n, Edge o _) = prO o <+> prettyTCM n
    prO Positive = text "-[+]->"
    prO Negative = text "-[-]->"
    prO Unused   = text "-[ ]->"

data Edge = Edge Occurrence OccursWhere
  deriving (Show)

instance SemiRing Edge where
  oplus e@(Edge Negative _) _                   = e
  oplus _                   e@(Edge Negative _) = e
  oplus (Edge Unused _)     e                   = e
  oplus e                   (Edge Unused _)     = e
  oplus e@(Edge Positive _) (Edge Positive _)   = e

  otimes (Edge o1 w1) (Edge o2 w2) = Edge (otimes o1 o2) (w1 >*< w2)

buildOccurrenceGraph :: Set QName -> TCM (AdjList Node Edge)
buildOccurrenceGraph qs = Map.unionsWith (++) <$> mapM defGraph (Set.toList qs)
  where
    defGraph :: QName -> TCM (AdjList Node Edge)
    defGraph q = do
      occs <- computeOccurrences q
      let onItem (item, occs) = do
            es <- mapM (computeEdge qs) occs
            return $ Map.singleton (itemToNode item) es
      Map.unionsWith (++) <$> mapM onItem (Map.assocs occs)
      where
        itemToNode (AnArg i) = ArgNode q i
        itemToNode (ADef q)  = DefNode q

-- | Given an 'OccursWhere' computes the target node and an 'Edge'. The first
--   argument is the set of names in the current mutual block.
computeEdge :: Set QName -> OccursWhere -> TCM (Node, Edge)
computeEdge muts o = do
  (to, occ) <- mkEdge __IMPOSSIBLE__ Positive o
  return (to, Edge occ o)
  where
    mkEdge to pol o = case o of
      Here           -> return (to, pol)
      Unknown        -> return (to, Negative)
      VarArg o       -> negative o
      MetaArg o      -> negative o
      LeftOfArrow o  -> negative o
      DefArg d i o
        | Set.member d muts -> inArg d i o
        | otherwise         -> addPol o =<< getArgOccurrence d i
      ConArgType _ o -> keepGoing o
      InClause _ o   -> keepGoing o
      InDefOf d o    -> mkEdge (DefNode d) Positive o
      where
        keepGoing     = mkEdge to pol
        negative      = mkEdge to Negative
        addPol o pol' = mkEdge to (otimes pol pol') o

        -- Reset polarity when changing the target node
        -- D: (A B -> C) generates a positive edge B --> A.1
        -- even though the context is negative.
        inArg d i = mkEdge (ArgNode d i) Positive

