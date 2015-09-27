module Erasure where
import Bound

import Annotation
import qualified Core
import qualified Lambda

type Core = Core.Expr
type Lambda = Lambda.Expr

erase :: HasRelevance a => Core a v -> Lambda v
erase expr = case expr of
  Core.Var v -> Lambda.Var v
  Core.Type -> undefined
  Core.Pi _ _ _ s -> erase $ instantiate1 undefined s
  Core.Lam h a _ s -> case relevance a of
    Irrelevant -> erase $ instantiate1 undefined s
    Relevant -> Lambda.Lam h $ toScope $ erase $ fromScope s
  Core.App e1 a e2 -> case relevance a of
    Irrelevant -> erase e1
    Relevant -> Lambda.App (erase e1) (erase e2)
  Core.Case {} -> undefined -- TODO
