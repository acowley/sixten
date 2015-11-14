{-# LANGUAGE BangPatterns, ViewPatterns, RecursiveDo #-}
module Infer where

import Bound
import Bound.Var
import Control.Applicative
import Control.Monad.Except
import Control.Monad.ST()
import Data.Bifunctor
import Data.Foldable as F
import qualified Data.HashMap.Lazy as HM
import Data.Monoid
import qualified Data.HashSet as HS
import Data.Vector(Vector)
import qualified Data.Vector as V

import Meta
import Monad
import Normalise
import qualified Syntax.Abstract as Abstract
import Syntax.Annotation
import Syntax.Branches
import qualified Syntax.Concrete as Concrete
import Syntax.Data
import Syntax.Definition
import Syntax.Hint
import TopoSort
import Unify
import Util

checkType :: Plicitness -> Concrete s -> Abstract s -> TCM s (Abstract s, Abstract s)
checkType surrounding expr typ = do
  tr "checkType e" expr
  tr "          t" =<< freeze typ
  modifyIndent succ
  (rese, rest) <- case expr of
    Concrete.Lam m p s -> do
      typ' <- whnf mempty plicitness typ
      case typ' of
        Abstract.Pi h p' a ts | p == p' -> do
          v <- forall_ (h <> m) a ()
          (body, ts') <- checkType surrounding
                                   (instantiate1 (pure v) s)
                                   (instantiate1 (pure v) ts)
          expr' <- Abstract.Lam (m <> h) p a <$> abstract1M v body
          typ'' <- Abstract.Pi  (h <> m) p a <$> abstract1M v ts'
          return (expr', typ'')
        Abstract.Pi h p' a ts | p' == Implicit -> do
          v <- forall_ h a ()
          (expr', ts') <- checkType surrounding expr (instantiate1 (pure v) ts)
          typ''  <- Abstract.Pi  h p' a <$> abstract1M v ts'
          expr'' <- Abstract.Lam h p' a <$> abstract1M v expr'
          return (expr'', typ'')
        _ -> inferIt
    _ -> inferIt
  modifyIndent pred
  tr "checkType res e" rese
  tr "              t" rest
  return (rese, rest)
    where
      inferIt = do
        (expr', typ') <- inferType surrounding expr
        subtype surrounding expr' typ' typ

inferType :: Plicitness -> Concrete s -> TCM s (Abstract s, Abstract s)
inferType surrounding expr = do
  tr "inferType" expr
  modifyIndent succ
  (e, t) <- case expr of
    Concrete.Global v -> do
      (_, typ, _) <- context v
      return (Abstract.Global v, first plicitness typ)
    Concrete.Var v -> return (Abstract.Var v, metaType v)
    Concrete.Con c -> do
      typ <- constructor c
      return (Abstract.Con c, first plicitness typ)
    Concrete.Type -> return (Abstract.Type, Abstract.Type)
    Concrete.Pi n p t s -> do
      (t', _) <- checkType p t Abstract.Type
      v  <- forall_ n t' ()
      (e', _) <- checkType surrounding (instantiate1 (pure v) s) Abstract.Type
      s' <- abstract1M v e'
      return (Abstract.Pi n p t' s', Abstract.Type)
    Concrete.Lam n p s -> uncurry generalise <=< enterLevel $ do
      a <- existsVar mempty Abstract.Type ()
      b <- existsVar mempty Abstract.Type ()
      x <- forall_ n a ()
      (e', b')  <- checkType surrounding (instantiate1 (pure x) s) b
      s' <- abstract1M x e'
      ab <- abstract1M x b'
      return (Abstract.Lam n p a s', Abstract.Pi n p a ab)
    Concrete.App e1 p e2 -> do
      a <- existsVar mempty Abstract.Type ()
      b <- existsVar mempty Abstract.Type ()
      (e1', e1type) <- checkType surrounding e1 $ Abstract.Pi mempty p a
                                                $ abstractNone b
      case e1type of
        Abstract.Pi _ p' a' b' | p == p' -> do
          (e2', _) <- checkType p e2 a'
          return (Abstract.App e1' p e2', instantiate1 e2' b')
        _ -> throwError "inferType: expected pi type"
    Concrete.Case e brs -> do
      (e', etype) <- inferType surrounding e
      (brs', retType) <- inferBranches surrounding brs etype
      return (Abstract.Case e' brs', retType)
    Concrete.Anno e t  -> do
      (t', _) <- checkType surrounding t Abstract.Type
      checkType surrounding e t'
    Concrete.Wildcard  -> do
      t <- existsVar mempty Abstract.Type ()
      x <- existsVar mempty t ()
      return (x, t)
  modifyIndent pred
  tr "inferType res e" e
  tr "              t" t
  return (e, t)

inferBranches :: Plicitness
              -> BranchesM Concrete.Expr s () Plicitness
              -> Abstract s
              -> TCM s (BranchesM (Abstract.Expr Plicitness) s () Plicitness, Abstract s)
inferBranches surrounding (ConBranches cbrs) etype = do
  forM cbrs $ \(c, hs, s) -> do
    undefined

  undefined
inferBranches surrounding (LitBranches lbrs d) etype = do
  unify etype undefined
  t <- existsVar mempty Abstract.Type ()
  lbrs' <- forM lbrs $ \(l, e) -> do
    (e', _) <- checkType surrounding e t
    return (l, e')
  (d', t') <- checkType surrounding d t

  return (LitBranches lbrs' d', t')

generalise :: Abstract s -> Abstract s -> TCM s (Abstract s, Abstract s)
generalise expr typ = do
  tr "generalise e" expr
  tr "           t" typ
  modifyIndent succ

  fvs <- foldMapM (:[]) typ
  l   <- level
  let p (metaRef -> Just r) = either (> l) (const False) <$> solution r
      p _                   = return False
  fvs' <- filterM p fvs

  deps <- HM.fromList <$> forM fvs' (\x -> do
    ds <- foldMapM HS.singleton $ metaType x
    return (x, ds)
   )
  let sorted = map go $ topoSort deps
  genexpr <- F.foldrM ($ Abstract.etaLam) expr sorted
  gentype <- F.foldrM ($ Abstract.Pi)     typ  sorted

  modifyIndent pred
  tr "generalise res ge" genexpr
  tr "               gt" gentype
  return (genexpr, gentype)
  where
    go [a] f = fmap (f (metaHint a) Implicit $ metaType a) . abstract1M a
    go _   _ = error "Generalise"

checkConstrDef :: Abstract s
               -> ConstrDef (Concrete s)
               -> TCM s (ConstrDef (Abstract s))
checkConstrDef typ (ConstrDef c (bindingsView Concrete.piView -> (args, ret))) = mdo
  let inst = instantiate (\n -> let (a, _, _, _) = args' V.! n in pure a)
  args' <- forM (V.fromList args) $ \(h, p, arg) -> do
    (arg', _) <- checkType p (inst arg) Abstract.Type
    v <- forall_ h arg' ()
    return (v, h, p, arg')
  (ret', _) <- checkType Explicit (inst ret) Abstract.Type
  unify ret' typ
  res <- F.foldrM (\(v, h, p, arg') rest ->
         Abstract.Pi h p arg' <$> abstract1M v rest) ret' args'
  return $ ConstrDef c res

extractParams :: Abstract.Expr p v -> Vector (NameHint, p, Scope Int (Abstract.Expr p) v)
extractParams (bindingsView Abstract.piView -> (ps, fromScope -> Abstract.Type))
  = V.fromList ps
extractParams _ = error "extractParams"

checkDataType :: MetaVar s () Plicitness
              -> DataDef Concrete.Expr (MetaVar s () Plicitness)
              -> Abstract s
              -> TCM s ( DataDef (Abstract.Expr Plicitness) (MetaVar s () Plicitness)
                       , Abstract s
                       )
checkDataType name (DataDef _ps cs) typ = mdo
  let inst = instantiate (\n -> let (v, _, _, _) = ps' V.! n in pure v)
  let inst' = instantiate (\n -> let (v, _, _, _) = ps' V.! n in pure v)

  ps' <- forM (extractParams typ) $ \(h, p, s) -> do
    let is = inst s
    v <- forall_ h is ()
    return (v, h, p, is)

  let vs = (\(v, _, _, _) -> v) <$> ps'
      retType = Abstract.apps (pure name) [(p, pure v) | (v, _, p, _) <- V.toList ps']

  params <- forM ps' $ \(_, h, p, t) -> (,,) h p <$> abstractM (`V.elemIndex` vs) t

  cs' <- forM cs $ \(ConstrDef c t) -> do
    res <- checkConstrDef retType (ConstrDef c $ inst' t)
    traverse (abstractM (`V.elemIndex` vs)) res

  return (DataDef params cs', typ)

subDefType :: Definition (Abstract.Expr Plicitness) (MetaVar s () Plicitness)
           -> Abstract s
           -> Abstract s
           -> TCM s ( Definition (Abstract.Expr Plicitness) (MetaVar s () Plicitness)
                    , Abstract s
                    )
subDefType (Definition e) t t' = first Definition <$> subtype Explicit e t t'
subDefType (DataDefinition d) t t' = do unify t t'; return (DataDefinition d, t')

generaliseDef :: Definition (Abstract.Expr Plicitness) (MetaVar s () Plicitness)
              -> Abstract s
              -> TCM s ( Definition (Abstract.Expr Plicitness) (MetaVar s () Plicitness)
                       , Abstract s
                       )
generaliseDef (Definition d) t = first Definition <$> generalise d t
generaliseDef (DataDefinition d) t = return (DataDefinition d, t)

abstractDefM :: Show a
             => (MetaVar s () a -> Maybe b)
             -> Definition (Abstract.Expr a) (MetaVar s () a)
             -> TCM s (Definition (Abstract.Expr a) (Var b (MetaVar s () a)))
abstractDefM f (Definition e) = Definition . fromScope <$> abstractM f e
abstractDefM f (DataDefinition e) = DataDefinition <$> abstractDataDefM f e

abstractDataDefM :: Show a
                 => (MetaVar s () a -> Maybe b)
                 -> DataDef (Abstract.Expr a) (MetaVar s () a)
                 -> TCM s (DataDef (Abstract.Expr a) (Var b (MetaVar s () a)))
abstractDataDefM f (DataDef ps cs) = mdo
  let inst = instantiate (pure . (vs V.!))
      vs = (\(_, _, _, v) -> v) <$> ps'
  ps' <- forM ps $ \(h, p, s) -> let is = inst s in (,,,) h p is <$> forall_ h is ()
  let f' x = F <$> f x <|> B <$> V.elemIndex x vs
  aps <- forM ps' $ \(h, p, s, _) -> (,,) h p <$> (toScope . fmap assoc . fromScope) <$> abstractM f' s
  acs <- forM cs $ \c -> traverse (fmap (toScope . fmap assoc . fromScope) . abstractM f' . inst) c
  return $ DataDef aps acs
  where
    assoc :: Var (Var a b) c -> Var a (Var b c)
    assoc = unvar (unvar B (F . B)) (F . F)

checkDefType :: MetaVar s () Plicitness
             -> Definition Concrete.Expr (MetaVar s () Plicitness)
             -> Abstract s
             -> TCM s ( Definition (Abstract.Expr Plicitness) (MetaVar s () Plicitness)
                      , Abstract s
                      )
checkDefType _ (Definition e) typ = first Definition <$> checkType Explicit e typ
checkDefType v (DataDefinition d) typ = first DataDefinition <$> checkDataType v d typ

checkRecursiveDefs :: Vector
                     ( NameHint
                     , Definition Concrete.Expr (Var Int (MetaVar s () Plicitness))
                     , ScopeM Int Concrete.Expr s () Plicitness
                     )
                   -> TCM s
                     (Vector ( Definition (Abstract.Expr Plicitness) (Var Int (MetaVar s () Plicitness))
                             , ScopeM Int (Abstract.Expr Plicitness) s () Plicitness
                             )
                     )
checkRecursiveDefs ds = do
  (evs, checkedDs) <- enterLevel $ do
    evs <- V.forM ds $ \(v, _, _) -> do
      tv <- existsVar mempty Abstract.Type ()
      forall_ v tv ()
    let instantiatedDs = flip V.map ds $ \(_, e, t) ->
          ( instantiateDef (pure . (evs V.!)) e
          , instantiate (pure . (evs V.!)) t
          )
    checkedDs <- sequence $ flip V.imap instantiatedDs $ \i (d, t) -> do
      (t', _) <- checkType Explicit t Abstract.Type
      (d', t'') <- checkDefType (evs V.! i) d t'
      subDefType d' t'' (metaType $ evs V.! i)
    return (evs, checkedDs)
  V.forM checkedDs $ \(d, t) -> do
    (gd, gt) <- generaliseDef d t
    -- tr "checkRecursiveDefs gd" gd
    tr "                   gt" gt
    s  <- abstractDefM (`V.elemIndex` evs) gd
    ts <- abstractM (`V.elemIndex` evs) gt
    return (s, ts)