{-# language RankNTypes #-}
{-# language ViewPatterns #-}
{-# language PatternGuards #-}
{-# language TypeApplications #-}
{-# language OverloadedStrings #-}
{-# language ScopedTypeVariables #-}
{-# language FunctionalDependencies #-}

module Unison.Runtime.Builtin
  ( builtinLookup
  , builtinTermNumbering
  , builtinTypeNumbering
  , builtinTermBackref
  , builtinTypeBackref
  , numberedTermLookup
  ) where

import Unison.ABT.Normalized hiding (TTm)
import Unison.Reference
import Unison.Runtime.ANF
import Unison.Var
import Unison.Symbol
import Unison.Runtime.IOSource

import qualified Unison.Type as Ty
import qualified Unison.Builtin.Decls as Ty

import Unison.Util.EnumContainers as EC

import Data.Word (Word64)

import Data.Set (Set, insert)

import Data.Map (Map)
import qualified Data.Map as Map

freshes :: Var v => Int -> [v]
freshes = freshes' mempty

freshes' :: Var v => Set v -> Int -> [v]
freshes' avoid0 = go avoid0 []
  where
  go _     vs 0 = vs
  go avoid vs n
    = let v = freshIn avoid $ typed ANFBlank
       in go (insert v avoid) (v:vs) (n-1)

boolTag, intTag, natTag, floatTag, charTag :: RTag
boolTag = rtag Ty.booleanRef
intTag = rtag Ty.intRef
natTag = rtag Ty.natRef
floatTag = rtag Ty.floatRef
charTag = rtag Ty.charRef

optionTag, eitherTag, pairTag, seqViewTag :: RTag
optionTag = rtag Ty.optionalRef
eitherTag = rtag eitherReference
pairTag = rtag Ty.pairRef
seqViewTag = rtag Ty.seqViewRef

fls, tru :: Var v => ANormal v
fls = TCon boolTag 0 []
tru = TCon boolTag 1 []

boolift :: Var v => v -> ANormalT v
boolift v
  = AMatch v $ MatchIntegral (mapFromList [(0,fls), (1,tru)]) Nothing

notlift :: Var v => v -> ANormalT v
notlift v
  = AMatch v $ MatchIntegral (mapFromList [(1,fls), (0,tru)]) Nothing

unbox :: Var v => v -> Reference -> v -> ANormal v -> ANormal v
unbox v0 r v b
  = TMatch v0
  $ MatchData r (mapSingleton 0 $ ([UN], TAbs v b)) Nothing

unenum :: Var v => Int -> v -> Reference -> v -> ANormal v -> ANormal v
unenum n v0 r v nx
  = TMatch v0 $ MatchData r cases Nothing
  where
  mkCase i = (toEnum i, ([], TLet v UN (ALit . I $ fromIntegral i) nx))
  cases = mapFromList . fmap mkCase $ [0..n-1]

unop0 :: Var v => Int -> ([v] -> ANormal v) -> SuperNormal v
unop0 n f
  = Lambda [BX]
  . TAbss [x0]
  $ f xs
  where
  xs@(x0:_) = freshes (1+n)

binop0 :: Var v => Int -> ([v] -> ANormal v) -> SuperNormal v
binop0 n f
  = Lambda [BX,BX]
  . TAbss [x0,y0]
  $ f xs
  where
  xs@(x0:y0:_) = freshes (2+n)

unop :: Var v => POp -> Reference -> SuperNormal v
unop pop rf = unop' pop rf rf

unop' :: Var v => POp -> Reference -> Reference -> SuperNormal v
unop' pop rfi rfo
  = unop0 2 $ \[x0,x,r]
 -> unbox x0 rfi x
  . TLet r UN (APrm pop [x])
  $ TCon (rtag rfo) 0 [r]

binop :: Var v => POp -> Reference -> SuperNormal v
binop pop rf = binop' pop rf rf rf

binop'
  :: Var v
  => POp
  -> Reference -> Reference -> Reference
  -> SuperNormal v
binop' pop rfx rfy rfr
  = binop0 3 $ \[x0,y0,x,y,r]
 -> unbox x0 rfx x
  . unbox y0 rfy y
  . TLet r UN (APrm pop [x,y])
  $ TCon (rtag rfr) 0 [r]

cmpop :: Var v => POp -> Reference -> SuperNormal v
cmpop pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLet b UN (APrm pop [x,y])
  $ TTm $ boolift b

cmpopb :: Var v => POp -> Reference -> SuperNormal v
cmpopb pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLet b UN (APrm pop [y,x])
  $ TTm $ boolift b

cmpopn :: Var v => POp -> Reference -> SuperNormal v
cmpopn pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLet b UN (APrm pop [x,y])
  $ TTm $ notlift b

cmpopbn :: Var v => POp -> Reference -> SuperNormal v
cmpopbn pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLet b UN (APrm pop [y,x])
  $ TTm $ notlift b

addi,subi,muli,divi,modi,shli,shri,powi :: Var v => SuperNormal v
addi = binop ADDI Ty.intRef
subi = binop SUBI Ty.intRef
muli = binop MULI Ty.intRef
divi = binop DIVI Ty.intRef
modi = binop MODI Ty.intRef
shli = binop' SHLI Ty.intRef Ty.natRef Ty.intRef
shri = binop' SHRI Ty.intRef Ty.natRef Ty.intRef
powi = binop' POWI Ty.intRef Ty.natRef Ty.intRef

addn,subn,muln,divn,modn,shln,shrn,pown :: Var v => SuperNormal v
addn = binop ADDN Ty.natRef
subn = binop' SUBN Ty.natRef Ty.natRef Ty.intRef
muln = binop MULN Ty.natRef
divn = binop DIVN Ty.natRef
modn = binop MODN Ty.natRef
shln = binop SHLN Ty.natRef
shrn = binop SHRN Ty.natRef
pown = binop POWN Ty.natRef

eqi, eqn, lti, ltn, lei, len :: Var v => SuperNormal v
eqi = cmpop EQLI Ty.intRef
lti = cmpopbn LEQI Ty.intRef
lei = cmpop LEQI Ty.intRef
eqn = cmpop EQLN Ty.natRef
ltn = cmpopbn LEQN Ty.natRef
len = cmpop LEQN Ty.natRef

gti, gtn, gei, gen :: Var v => SuperNormal v
gti = cmpopn LEQI Ty.intRef
gei = cmpopb LEQI Ty.intRef
gtn = cmpopn LEQN Ty.intRef
gen = cmpopb LEQN Ty.intRef

neqi, neqn :: Var v => SuperNormal v
neqi = cmpopn EQLI Ty.intRef
neqn = cmpopn EQLN Ty.intRef

inci, incn :: Var v => SuperNormal v
inci = unop INCI Ty.intRef
incn = unop INCN Ty.natRef

sgni, negi :: Var v => SuperNormal v
sgni = unop SGNI Ty.intRef
negi = unop NEGI Ty.intRef

lzeron, tzeron, lzeroi, tzeroi :: Var v => SuperNormal v
lzeron = unop LZRO Ty.natRef
tzeron = unop TZRO Ty.natRef
lzeroi = unop' LZRO Ty.intRef Ty.natRef
tzeroi = unop' TZRO Ty.intRef Ty.natRef

andn, orn, xorn, compln :: Var v => SuperNormal v
andn = binop ANDN Ty.natRef
orn = binop IORN Ty.natRef
xorn = binop XORN Ty.natRef
compln = unop COMN Ty.natRef

addf, subf, mulf, divf, powf, sqrtf, logf, logbf
  :: Var v => SuperNormal v
addf = binop ADDF Ty.floatRef
subf = binop SUBF Ty.floatRef
mulf = binop MULF Ty.floatRef
divf = binop DIVF Ty.floatRef
powf = binop POWF Ty.floatRef
sqrtf = unop SQRT Ty.floatRef
logf = unop LOGF Ty.floatRef
logbf = binop LOGB Ty.floatRef

expf, absf :: Var v => SuperNormal v
expf = unop EXPF Ty.floatRef
absf = unop ABSF Ty.floatRef

cosf, sinf, tanf, acosf, asinf, atanf :: Var v => SuperNormal v
cosf = unop COSF Ty.floatRef
sinf = unop SINF Ty.floatRef
tanf = unop TANF Ty.floatRef
acosf = unop ACOS Ty.floatRef
asinf = unop ASIN Ty.floatRef
atanf = unop ATAN Ty.floatRef

coshf, sinhf, tanhf, acoshf, asinhf, atanhf, atan2f
  :: Var v => SuperNormal v
coshf = unop COSH Ty.floatRef
sinhf = unop SINH Ty.floatRef
tanhf = unop TANH Ty.floatRef
acoshf = unop ACSH Ty.floatRef
asinhf = unop ASNH Ty.floatRef
atanhf = unop ATNH Ty.floatRef
atan2f = binop ATN2 Ty.floatRef

ltf, gtf, lef, gef, eqf, neqf :: Var v => SuperNormal v
ltf = cmpopbn LEQF Ty.floatRef
gtf = cmpopn LEQF Ty.floatRef
lef = cmpop LEQF Ty.floatRef
gef = cmpopb LEQF Ty.floatRef
eqf = cmpop EQLF Ty.floatRef
neqf = cmpopn EQLF Ty.floatRef

minf, maxf :: Var v => SuperNormal v
minf = binop MINF Ty.floatRef
maxf = binop MAXF Ty.floatRef

ceilf, floorf, truncf, roundf, i2f, n2f :: Var v => SuperNormal v
ceilf = unop' CEIL Ty.floatRef Ty.intRef
floorf = unop' FLOR Ty.floatRef Ty.intRef
truncf = unop' TRNF Ty.floatRef Ty.intRef
roundf = unop' RNDF Ty.floatRef Ty.intRef
i2f = unop' ITOF Ty.intRef Ty.floatRef
n2f = unop' NTOF Ty.natRef Ty.floatRef

trni :: Var v => SuperNormal v
trni = unop0 3 $ \[x0,x,z,b]
    -> unbox x0 Ty.intRef x
     . TLet z UN (ALit $ I 0)
     . TLet b UN (APrm LEQI [x, z])
     . TMatch b
     $ MatchIntegral
         (mapSingleton 1 $ TCon natTag 0 [z])
         (Just $ TCon natTag 0 [x])

modular :: Var v => POp -> (Bool -> ANormal v) -> SuperNormal v
modular pop ret
  = unop0 3 $ \[x0,x,m,t]
 -> unbox x0 Ty.intRef x
  . TLet t UN (ALit $ I 2)
  . TLet m UN (APrm pop [x,t])
  . TMatch m
  $ MatchIntegral
      (mapSingleton 1 $ ret True)
      (Just $ ret False)

evni, evnn, oddi, oddn :: Var v => SuperNormal v
evni = modular MODI (\b -> if b then fls else tru)
oddi = modular MODI (\b -> if b then tru else fls)
evnn = modular MODN (\b -> if b then fls else tru)
oddn = modular MODN (\b -> if b then tru else fls)

dropn :: Var v => SuperNormal v
dropn = binop0 4 $ \[x0,y0,x,y,b,r]
     -> unbox x0 Ty.natRef x
      . unbox y0 Ty.natRef y
      . TLet b UN (APrm LEQN [x,y])
      . TLet r UN
          (AMatch b $ MatchIntegral
             (mapSingleton 1 $ TLit $ N 0)
             (Just $ TPrm SUBN [x,y]))
      $ TCon (rtag Ty.natRef) 0 [r]

appendt, taket, dropt, sizet, unconst, unsnoct :: Var v => SuperNormal v
appendt = binop0 0 $ \[x,y] -> TPrm CATT [x,y]
taket = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm TAKT [x,y]
dropt = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm DRPT [x,y]
sizet = unop0 1 $ \[x,r]
     -> TLet r UN (APrm SIZT [x])
      $ TCon (rtag Ty.natRef) 0 [r]
unconst = unop0 5 $ \[x,t,c0,c,y,p]
     -> TLet t UN (APrm UCNS [x])
      . TMatch t . MatchSum $ mapFromList
      [ (0, ([], TCon optionTag 0 []))
      , (1, ([UN,BX], TAbss [c0,y]
                    . TLet c BX (ACon charTag 0 [c0])
                    . TLet p BX (ACon pairTag 0 [c,y])
                    $ TCon optionTag 1 [p]))
      ]
unsnoct = unop0 5 $ \[x,t,c0,c,y,p]
     -> TLet t UN (APrm USNC [x])
      . TMatch t . MatchSum $ mapFromList
      [ (0, ([], TCon optionTag 0 []))
      , (1, ([BX,UN], TAbss [y,c0]
                    . TLet c BX (ACon charTag 0 [c0])
                    . TLet p BX (ACon pairTag 0 [y,c])
                    $ TCon optionTag 1 [p]))
      ]

appends, conss, snocs :: Var v => SuperNormal v
appends = binop0 0 $ \[x,y] -> TPrm CATS [x,y]
conss = binop0 0 $ \[x,y] -> TPrm CONS [x,y]
snocs = binop0 0 $ \[x,y] -> TPrm SNOC [x,y]

takes, drops, sizes, ats, emptys :: Var v => SuperNormal v
takes = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm TAKS [x,y]
drops = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm DRPS [x,y]
sizes = unop0 1 $ \[x,r]
     -> TLet r UN (APrm SIZS [x])
      $ TCon natTag 0 [r]
ats = binop0 3 $ \[x0,y,x,t,r]
   -> unbox x0 Ty.natRef x
    . TLet t UN (APrm IDXS [x,y])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon optionTag 0 []))
    , (1, ([BX], TAbs r $ TCon optionTag 1 [r]))
    ]
emptys = Lambda [] $ TPrm BLDS []

viewls, viewrs :: Var v => SuperNormal v
viewls = unop0 3 $ \[s,u,h,t]
      -> TLet u UN (APrm VWLS [s])
       . TMatch u . MatchSum $ mapFromList
       [ (0, ([], TCon seqViewTag 0 []))
       , (1, ([BX,BX], TAbss [h,t] $ TCon seqViewTag 1 [h,t]))
       ]
viewrs = unop0 3 $ \[s,u,i,l]
      -> TLet u UN (APrm VWRS [s])
       . TMatch u . MatchSum $ mapFromList
       [ (0, ([], TCon seqViewTag 0 []))
       , (1, ([BX,BX], TAbss [i,l] $ TCon seqViewTag 1 [i,l]))
       ]

eqt, neqt, leqt, geqt, lesst, great :: Var v => SuperNormal v
eqt = binop0 1 $ \[x,y,b]
   -> TLet b UN (APrm EQLT [x,y])
    . TTm $ boolift b
neqt = binop0 1 $ \[x,y,b]
    -> TLet b UN (APrm EQLT [x,y])
     . TTm $ notlift b
leqt = binop0 1 $ \[x,y,b]
    -> TLet b UN (APrm LEQT [x,y])
     . TTm $ boolift b
geqt = binop0 1 $ \[x,y,b]
    -> TLet b UN (APrm LEQT [y,x])
     . TTm $ boolift b
lesst = binop0 1 $ \[x,y,b]
     -> TLet b UN (APrm LEQT [y,x])
      . TTm $ notlift b
great = binop0 1 $ \[x,y,b]
     -> TLet b UN (APrm LEQT [x,y])
      . TTm $ notlift b

packt, unpackt :: Var v => SuperNormal v
packt = unop0 0 $ \[s] -> TPrm PAKT [s]
unpackt = unop0 0 $ \[t] -> TPrm UPKT [t]

i2t, n2t, f2t :: Var v => SuperNormal v
i2t = unop0 1 $ \[n0,n]
   -> unbox n0 Ty.intRef n
    $ TPrm ITOT [n]
n2t = unop0 1 $ \[n0,n]
   -> unbox n0 Ty.natRef n
    $ TPrm NTOT [n]
f2t = unop0 1 $ \[f0,f]
   -> unbox f0 Ty.floatRef f
    $ TPrm FTOT [f]

t2i, t2n, t2f :: Var v => SuperNormal v
t2i = unop0 3 $ \[x,t,n0,n]
   -> TLet t UN (APrm TTOI [x])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon optionTag 0 []))
    , (1, ([UN], TAbs n0
               . TLet n BX (ACon intTag 0 [n0])
               $ TCon optionTag 1 [n]))
    ]
t2n = unop0 3 $ \[x,t,n0,n]
   -> TLet t UN (APrm TTON [x])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon optionTag 0 []))
    , (1, ([UN], TAbs n0
               . TLet n BX (ACon natTag 0 [n0])
               $ TCon optionTag 1 [n]))
    ]
t2f = unop0 3 $ \[x,t,f0,f]
   -> TLet t UN (APrm TTOF [x])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon optionTag 0 []))
    , (1, ([UN], TAbs f0
               . TLet f BX (ACon floatTag 0 [f0])
               $ TCon optionTag 1 [f]))
    ]

equ :: Var v => SuperNormal v
equ = binop0 1 $ \[x,y,b]
   -> TLet b UN (APrm EQLU [x,y])
    . TTm $ boolift b

cmpu :: Var v => SuperNormal v
cmpu = binop0 2 $ \[x,y,c,i]
    -> TLet c UN (APrm CMPU [x,y])
     . TLet i UN (APrm DECI [c])
     $ TCon intTag 0 [i]

ltu :: Var v => SuperNormal v
ltu = binop0 1 $ \[x,y,c]
   -> TLet c UN (APrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (0, TCon boolTag 1 []) ])
        (Just $ TCon boolTag 0 [])

gtu :: Var v => SuperNormal v
gtu = binop0 1 $ \[x,y,c]
   -> TLet c UN (APrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (2, TCon boolTag 1 []) ])
        (Just $ TCon boolTag 0 [])

geu :: Var v => SuperNormal v
geu = binop0 1 $ \[x,y,c]
   -> TLet c UN (APrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (0, TCon boolTag 0 []) ])
        (Just $ TCon boolTag 1 [])

leu :: Var v => SuperNormal v
leu = binop0 1 $ \[x,y,c]
   -> TLet c UN (APrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (2, TCon boolTag 0 []) ])
        (Just $ TCon boolTag 1 [])

notb :: Var v => SuperNormal v
notb = unop0 0 $ \[b]
    -> TMatch b . flip (MatchData Ty.booleanRef) Nothing
     $ mapFromList [ (0, ([], tru)), (1, ([], fls)) ]

orb :: Var v => SuperNormal v
orb = binop0 0 $ \[p,q]
   -> TMatch p . flip (MatchData Ty.booleanRef) Nothing
    $ mapFromList [ (1, ([], tru)), (0, ([], TVar q)) ]

andb :: Var v => SuperNormal v
andb = binop0 0 $ \[p,q]
    -> TMatch p . flip (MatchData Ty.booleanRef) Nothing
     $ mapFromList [ (0, ([], fls)), (1, ([], TVar q)) ]

-- unsafeCoerce, used for numeric types where conversion is a
-- no-op on the representation. Ideally this will be inlined and
-- eliminated so that no instruction is necessary.
cast :: Var v => Reference -> Reference -> SuperNormal v
cast ri ro
  = unop0 1 $ \[x0,x]
 -> unbox x0 ri x
  $ TCon (rtag ro) 0 [x]

jumpk :: Var v => SuperNormal v
jumpk = binop0 0 $ \[k,a] -> TKon k [a]

bug :: Var v => SuperNormal v
bug = unop0 0 $ \[x] -> TPrm EROR [x]

watch :: Var v => SuperNormal v
watch
  = binop0 0 $ \[t,v]
 -> TLets [] [] (APrm PRNT [t])
  $ TVar v

type IOOP = forall v. Var v => Set v -> ([Mem], ANormal v)

io'error'result0
  :: Var v
  => IOp -> [v]
  -> v -> [Mem] -> [v] -> v
  -> ANormal v -> ANormal v
io'error'result0 ins args ior ccs vs e nx
  = TLet ior UN (AIOp ins args)
  . TMatch ior . MatchSum
  $ mapFromList
  [ (0, ([BX], TAbs e $ TCon eitherTag 0 [e]))
  , (1, (ccs, TAbss vs nx))
  ]

io'error'result'let
  :: Var v
  => IOp -> [v]
  -> v -> [Mem] -> [v] -> v -> v -> ANormalT v
  -> ANormal v
io'error'result'let ins args ior ccs vs e r m
  = io'error'result0 ins args ior ccs vs e
  . TLet r BX m
  $ TCon eitherTag 1 [r]

io'error'result'direct
  :: Var v
  => IOp -> [v]
  -> v -> v -> v
  -> ANormal v
io'error'result'direct ins args ior e r
  = io'error'result0 ins args ior [BX] [r] e
  $ TCon eitherTag 1 [r]

io'error'result'unit
  :: Var v
  => IOp -> [v]
  -> v -> v -> v
  -> ANormal v
io'error'result'unit ins args ior e r
  = io'error'result'let ins args ior [] [] e r
  $ ACon (rtag Ty.unitRef) 0 []

io'error'result'bool
  :: Var v
  => IOp -> [v]
  -> v -> (v -> ANormalT v) -> v -> v -> v -> ANormal v
io'error'result'bool ins args ior encode b e r
  = io'error'result'let ins args ior [UN] [b] e r
  $ encode b

open'file :: IOOP
open'file avoid
  = ([BX,BX],)
  . TAbss [fp,m0]
  . unenum 4 m0 ioModeReference m
  $ io'error'result'direct OPENFI [fp,m] ior e r
  where
  [m0,fp,m,ior,e,r] = freshes' avoid 6

close'file :: IOOP
close'file avoid
  = ([BX],)
  . TAbss [h]
  $ io'error'result'unit CLOSFI [h] ior e r
  where
  [h,ior,e,r] = freshes' avoid 4

is'file'eof :: IOOP
is'file'eof avoid
  = ([BX],)
  . TAbss [h]
  $ io'error'result'bool ISFEOF [h] ior boolift b e r
  where
  [h,b,ior,e,r] = freshes' avoid 5

is'file'open :: IOOP
is'file'open avoid
  = ([BX],)
  . TAbss [h]
  $ io'error'result'bool ISFOPN [h] ior boolift b e r
  where
  [h,b,ior,e,r] = freshes' avoid 5

is'seekable :: IOOP
is'seekable avoid
  = ([BX],)
  . TAbss [h]
  $ io'error'result'bool ISSEEK [h] ior boolift b e r
  where
  [h,b,ior,e,r] = freshes' avoid 5

standard'handle :: IOOP
standard'handle avoid
  = ([BX],)
  . TAbss [n0]
  . unbox n0 Ty.natRef n
  . TLet r UN (AIOp STDHND [n])
  . TMatch r . MatchSum
  $ mapFromList
  [ (0, ([], TCon optionTag 0 []))
  , (1, ([BX], TAbs h $ TCon optionTag 1 [h]))
  ]
  where
  [n0,n,h,r] = freshes' avoid 4

seek'handle :: IOOP
seek'handle avoid
  = ([BX,BX,BX],)
  . TAbss [h,sm0,po0]
  . unenum 3 sm0 seekModeReference sm
  . unbox po0 Ty.natRef po
  $ io'error'result'unit SEEKFI [h,sm,po] ior e r
  where
  [sm0,po0,h,sm,po,ior,e,r] = freshes' avoid 8

handle'position :: IOOP
handle'position avoid
  = ([BX],)
  . TAbss [h]
  . io'error'result'let POSITN [h] ior [UN] [i] e r
  $ (ACon (rtag Ty.intRef) 0 [i])
  where
  [h,i,ior,e,r] = freshes' avoid 5

get'buffering :: IOOP
get'buffering avoid
  = ([BX],)
  . TAbss [h]
  . io'error'result'let GBUFFR [h] ior [UN] [bu] e r
  . AMatch bu . MatchSum
  $ mapFromList
  [ (0, ([], TCon (rtag Ty.optionalRef) 0 []))
  , (1, ([], line))
  , (2, ([], block'nothing))
  , (3, ([UN], TAbs n $ block'n))
  ]
  where
  [h,bu,ior,e,r,m,n,b] = freshes' avoid 8
  final = TCon (rtag Ty.optionalRef) 1 [b]
  block = TLet b BX (ACon (rtag bufferModeReference) 1 [m]) $ final

  line
    = TLet b BX (ACon (rtag bufferModeReference) 0 []) $ final
  block'nothing
    = TLet m BX (ACon (rtag Ty.optionalRef) 0 [])
    $ block
  block'n
    = TLet m BX (ACon (rtag Ty.optionalRef) 1 [n])
    $ block

set'buffering :: IOOP
set'buffering avoid
  = ([BX,BX],)
  . TAbss [h,bm0]
  . TMatch bm0 . flip (MatchData Ty.optionalRef) Nothing
  $ mapFromList
  [ (0, ([], none'branch))
  , (1, ([BX], TAbs bm just'branch'0))
  ]
  where
  [t,ior,e,r,h,mbs,bs0,bs,bm0,bm] = freshes' avoid 10
  none'branch
    = TLet t UN (ALit $ I 0)
    $ io'error'result'unit SBUFFR [h,t] ior e r
  just'branch'0
    = TMatch bm . flip (MatchData bufferModeReference) Nothing
    $ mapFromList
    [ (0, ([]
        , TLet t UN (ALit $ I 1)
        $ io'error'result'unit SBUFFR [h,t] ior e r
        ))
    , (1, ([BX], TAbs mbs just'branch'1))
    ]
  just'branch'1
    = TMatch mbs
      . flip (MatchData Ty.optionalRef) Nothing
      $ mapFromList
      [ (0, ([]
          , TLet t UN (ALit $ I 2)
          $ io'error'result'unit SBUFFR [h,t] ior e r))
      , (1, ([BX]
          , TAbs bs0
          . unbox bs0 Ty.natRef bs
          . TLet t UN (ALit $ I 3)
          $ io'error'result'unit SBUFFR [h,t,bs] ior e r))
      ]

get'line :: IOOP
get'line avoid
  = ([BX],)
  . TAbss [h]
  $ io'error'result'direct GTLINE [h] ior e r
  where
  [h,ior,e,r] = freshes' avoid 4

get'text :: IOOP
get'text avoid
  = ([BX],)
  . TAbss [h]
  $ io'error'result'direct GTTEXT [h] ior e r
  where
  [h,ior,e,r] = freshes' avoid 4

put'text :: IOOP
put'text avoid
  = ([BX,BX],)
  . TAbss [h,tx]
  $ io'error'result'direct PUTEXT [h,tx] ior e r
  where
  [h,tx,ior,e,r] = freshes' avoid 5

system'time :: IOOP
system'time avoid
  = ([],)
  . io'error'result'let SYTIME [] ior [UN] [n] e r
  $ ACon (rtag Ty.natRef) 0 [n]
  where
  [n,ior,e,r] = freshes' avoid 4

get'temp'directory :: IOOP
get'temp'directory avoid
  = ([],)
  . io'error'result'let GTMPDR [] ior [BX] [t] e r
  $ ACon (rtag filePathReference) 0 [t]
  where
  [t,ior,e,r] = freshes' avoid 4

get'current'directory :: IOOP
get'current'directory avoid
  = ([],)
  . io'error'result'let GCURDR [] ior [BX] [t] e r
  $ ACon (rtag filePathReference) 0 [r]
  where
  [t,e,r,ior] = freshes' avoid 4

set'current'directory :: IOOP
set'current'directory avoid
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit SCURDR [fp] ior e r
  where
  [fp,ior,e,r] = freshes' avoid 4

-- directory'contents
-- DCNTNS
--   directoryContents_ : io.FilePath -> Either io.Error [io.FilePath]


file'exists :: IOOP
file'exists avoid
  = ([BX],)
  . TAbs fp
  $ io'error'result'bool FEXIST [fp] ior boolift b e r
  where
  [fp,b,ior,e,r] = freshes' avoid 5

is'directory :: IOOP
is'directory avoid
  = ([BX],)
  . TAbs fp
  $ io'error'result'bool ISFDIR [fp] ior boolift b e r
  where
  [fp,b,ior,e,r] = freshes' avoid 5

create'directory :: IOOP
create'directory avoid
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit CRTDIR [fp] ior e r
  where
  [fp,ior,e,r] = freshes' avoid 4

remove'directory :: IOOP
remove'directory avoid
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit REMDIR [fp] ior e r
  where
  [fp,ior,e,r] = freshes' avoid 4

rename'directory :: IOOP
rename'directory avoid
  = ([BX,BX],)
  . TAbss [from,to]
  $ io'error'result'unit RENDIR [from,to] ior e r
  where
  [from,to,ior,e,r] = freshes' avoid 5

remove'file :: IOOP
remove'file avoid
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit REMOFI [fp] ior e r
  where
  [fp,ior,e,r] = freshes' avoid 4

rename'file :: IOOP
rename'file avoid
  = ([BX,BX],)
  . TAbss [from,to]
  $ io'error'result'unit RENAFI [from,to] ior e r
  where
  [from,to,ior,e,r] = freshes' avoid 5

get'file'timestamp :: IOOP
get'file'timestamp avoid
  = ([BX],)
  . TAbs fp
  . io'error'result'let GFTIME [fp] ior [UN] [n] e r
  $ ACon (rtag Ty.natRef) 0 [n]
  where
  [fp,n,ior,e,r] = freshes' avoid 5

get'file'size :: IOOP
get'file'size avoid
  = ([BX],)
  . TAbs fp
  . io'error'result'let GFSIZE [fp] ior [UN] [n] e r
  $ ACon (rtag Ty.natRef) 0 [n]
  where
  [fp,n,ior,e,r] = freshes' avoid 5

server'socket :: IOOP
server'socket avoid
  = ([BX,BX],)
  . TAbss [mhn,sn]
  . TMatch mhn . flip (MatchData Ty.optionalRef) Nothing
  $ mapFromList
  [ (0, ([], none'branch))
  , (1, ([BX], TAbs hn just'branch))
  ]
  where
  [mhn,sn,hn,t,ior,e,r] = freshes' avoid 7
  none'branch
    = TLet t UN (ALit $ I 0)
    $ io'error'result'direct SRVSCK [t,sn] ior e r
  just'branch
    = TLet t UN (ALit $ I 1)
    $ io'error'result'direct SRVSCK [t,hn,sn] ior e r

listen :: IOOP
listen avoid
  = ([BX],)
  . TAbs sk
  $ io'error'result'direct LISTEN [sk] ior e r
  where
  [sk,ior,e,r] = freshes' avoid 4

client'socket :: IOOP
client'socket avoid
  = ([BX,BX],)
  . TAbss [hn,sn]
  $ io'error'result'direct CLISCK [hn,sn] ior e r
  where
  [hn,sn,r,ior,e] = freshes' avoid 5

close'socket :: IOOP
close'socket avoid
  = ([BX,BX],)
  . TAbs sk
  $ io'error'result'unit CLOSCK [sk] ior e r
  where
  [sk,ior,e,r] = freshes' avoid 4

socket'accept :: IOOP
socket'accept avoid
  = ([BX],)
  . TAbs sk
  $ io'error'result'direct SKACPT [sk] ior e r
  where
  [sk,r,e,ior] = freshes' avoid 4

socket'send :: IOOP
socket'send avoid
  = ([BX,BX],)
  . TAbss [sk,by]
  $ io'error'result'unit SKSEND [sk,by] ior e r
  where
  [sk,by,ior,e,r] = freshes' avoid 5

socket'receive :: IOOP
socket'receive avoid
  = ([BX,BX],)
  . TAbss [sk,n0]
  . unbox n0 Ty.natRef n
  . io'error'result'let SKRECV [sk,n] ior [UN] [mt] e r
  . AMatch mt . MatchSum
  $ mapFromList
  [ (0, ([], TCon (rtag Ty.optionalRef) 0 []))
  , (1, ([BX], TAbs b $ TCon (rtag Ty.optionalRef) 1 [b]))
  ]
  where
  [n0,sk,n,ior,e,r,b,mt] = freshes' avoid 8

fork'comp :: IOOP
fork'comp avoid
  = ([BX],)
  . TAbs lz
  $ TPrm FORK [lz]
  where
  [lz] = freshes' avoid 3

builtinLookup :: Var v => Map.Map Reference (SuperNormal v)
builtinLookup
  = Map.fromList
  $ map (\(t, f) -> (Builtin t, f))
  [ ("Int.+", addi)
  , ("Int.-", subi)
  , ("Int.*", muli)
  , ("Int./", divi)
  , ("Int.mod", modi)
  , ("Int.==", eqi)
  , ("Int.!=", neqi)
  , ("Int.<", lti)
  , ("Int.<=", lei)
  , ("Int.>", gti)
  , ("Int.>=", gei)
  , ("Int.increment", inci)
  , ("Int.signum", sgni)
  , ("Int.negate", negi)
  , ("Int.truncate0", trni)
  , ("Int.isEven", evni)
  , ("Int.isOdd", oddi)
  , ("Int.shiftLeft", shli)
  , ("Int.shiftRight", shri)
  , ("Int.trailingZeros", tzeroi)
  , ("Int.leadingZeros", lzeroi)
  , ("Int.pow", powi)
  , ("Int.toText", i2t)
  , ("Int.fromText", t2i)
  , ("Int.toFloat", i2f)

  , ("Nat.+", addn)
  , ("Nat.-", subn)
  , ("Nat.sub", subn)
  , ("Nat.*", muln)
  , ("Nat./", divn)
  , ("Nat.mod", modn)
  , ("Nat.==", eqn)
  , ("Int.!=", neqn)
  , ("Nat.<", ltn)
  , ("Nat.<=", len)
  , ("Nat.>", gtn)
  , ("Nat.>=", gen)
  , ("Nat.increment", incn)
  , ("Nat.isEven", evnn)
  , ("Nat.isOdd", oddn)
  , ("Nat.shiftLeft", shln)
  , ("Nat.shiftRight", shrn)
  , ("Nat.trailingZeros", tzeron)
  , ("Nat.leadingZeros", lzeron)
  , ("Nat.and", andn)
  , ("Nat.or", orn)
  , ("Nat.xor", xorn)
  , ("Nat.complement", compln)
  , ("Nat.pow", pown)
  , ("Nat.drop", dropn)
  , ("Nat.toInt", cast Ty.natRef Ty.intRef)
  , ("Nat.toFloat", n2f)
  , ("Nat.toText", n2t)
  , ("Nat.fromText", t2n)

  , ("Float.+", addf)
  , ("Float.-", subf)
  , ("Float.*", mulf)
  , ("Float./", divf)
  , ("Float.pow", powf)
  , ("Float.log", logf)
  , ("Float.logBase", logbf)
  , ("Float.sqrt", sqrtf)

  , ("Float.min", minf)
  , ("Float.max", maxf)

  , ("Float.<", ltf)
  , ("Float.>", gtf)
  , ("Float.<=", lef)
  , ("Float.>=", gef)
  , ("Float.==", eqf)
  , ("Float.!=", neqf)

  , ("Float.acos", acosf)
  , ("Float.asin", asinf)
  , ("Float.atan", atanf)
  , ("Float.cos", cosf)
  , ("Float.sin", sinf)
  , ("Float.tan", tanf)

  , ("Float.acosh", acoshf)
  , ("Float.asinh", asinhf)
  , ("Float.atanh", atanhf)
  , ("Float.cosh", coshf)
  , ("Float.sinh", sinhf)
  , ("Float.tanh", tanhf)

  , ("Float.exp", expf)
  , ("Float.abs", absf)

  , ("Float.ceiling", ceilf)
  , ("Float.floor", floorf)
  , ("Float.round", roundf)
  , ("Float.truncate", truncf)
  , ("Float.atan2", atan2f)

  , ("Float.toText", f2t)
  , ("Float.fromText", t2f)

  -- text
  , ("Text.empty", Lambda [] $ TLit (T ""))
  , ("Text.++", appendt)
  , ("Text.take", taket)
  , ("Text.drop", dropt)
  , ("Text.size", sizet)
  , ("Text.==", eqt)
  , ("Text.!=", neqt)
  , ("Text.<=", leqt)
  , ("Text.>=", geqt)
  , ("Text.<", lesst)
  , ("Text.>", great)
  , ("Text.uncons", unconst)
  , ("Text.unsnoc", unsnoct)
  , ("Text.toCharList", unpackt)
  , ("Text.fromCharList", packt)

  , ("Boolean.not", notb)
  , ("Boolean.or", orb)
  , ("Boolean.and", andb)

  , ("bug", bug)
  , ("todo", bug)
  , ("Debug.watch", watch)

  , ("Char.toNat", cast Ty.charRef Ty.natRef)
  , ("Char.fromNat", cast Ty.natRef Ty.charRef)

--   , B "Bytes.empty" bytes
--   , B "Bytes.fromList" $ list nat --> bytes
--   , B "Bytes.++" $ bytes --> bytes --> bytes
--   , B "Bytes.take" $ nat --> bytes --> bytes
--   , B "Bytes.drop" $ nat --> bytes --> bytes
--   , B "Bytes.at" $ nat --> bytes --> optional nat
--   , B "Bytes.toList" $ bytes --> list nat
--   , B "Bytes.size" $ bytes --> nat
--   , B "Bytes.flatten" $ bytes --> bytes

  , ("List.take", takes)
  , ("List.drop", drops)
  , ("List.size", sizes)
  , ("List.++", appends)
  , ("List.at", ats)
  , ("List.cons", conss)
  , ("List.snoc", snocs)
  , ("List.empty", emptys)
  , ("List.viewl", viewls)
  , ("List.viewr", viewrs)
--
--   , B "Debug.watch" $ forall1 "a" (\a -> text --> a --> a)
  , ("Universal.==", equ)
  , ("Universal.compare", cmpu)
  , ("Universal.>", gtu)
  , ("Universal.<", ltu)
  , ("Universal.>=", geu)
  , ("Universal.<=", leu)

  , ("jumpCont", jumpk)

  , ("IO.openFile", ioComb open'file)
  , ("IO.closeFile", ioComb close'file)
  , ("IO.isFileEOF", ioComb is'file'eof)
  , ("IO.isFileOpen", ioComb is'file'open)
  , ("IO.isSeekable", ioComb is'seekable)
  , ("IO.seekHandle", ioComb seek'handle)
  , ("IO.handlePosition", ioComb handle'position)
  , ("IO.getBuffering", ioComb get'buffering)
  , ("IO.setBuffering", ioComb set'buffering)
  , ("IO.getLine", ioComb get'line)
  , ("IO.getText", ioComb get'text)
  , ("IO.putText", ioComb put'text)
  , ("IO.systemTime", ioComb system'time)
  , ("IO.getTempDirectory", ioComb get'temp'directory)
  , ("IO.getCurrentDirectory", ioComb get'current'directory)
  , ("IO.setCurrentDirectory", ioComb set'current'directory)
  , ("IO.fileExists", ioComb file'exists)
  , ("IO.isDirectory", ioComb is'directory)
  , ("IO.createDirectory", ioComb create'directory)
  , ("IO.removeDirectory", ioComb remove'directory)
  , ("IO.renameDirectory", ioComb rename'directory)
  , ("IO.removeFile", ioComb remove'file)
  , ("IO.renameFile", ioComb rename'file)
  , ("IO.getFileTimestamp", ioComb get'file'timestamp)
  , ("IO.getFileSize", ioComb get'file'size)
  , ("IO.serverSocket", ioComb server'socket)
  , ("IO.listen", ioComb listen)
  , ("IO.clientSocket", ioComb client'socket)
  , ("IO.closeSocket", ioComb close'socket)
  , ("IO.socketAccept", ioComb socket'accept)
  , ("IO.socketSend", ioComb socket'send)
  , ("IO.socketReceive", ioComb socket'receive)
  , ("IO.forkComp", ioComb fork'comp)
  , ("IO.stdHandle", ioComb standard'handle)
  ]

ioComb :: Var v => IOOP -> SuperNormal v
ioComb ioop = uncurry Lambda (ioop mempty)

typeReferences :: [(Reference, RTag)]
typeReferences
  = zip
  [ Ty.natRef
  , Ty.optionalRef
  , Ty.unitRef
  , Ty.pairRef
  , Ty.booleanRef
  , Ty.intRef
  , Ty.floatRef
  , Ty.booleanRef
  , Ty.textRef
  , Ty.charRef
  , eitherReference
  , filePathReference
  , bufferModeReference
  , Ty.effectRef
  , Ty.vectorRef
  , Ty.seqViewRef
  ] [1..]

numberedTermLookup :: Var v => EnumMap Word64 (SuperNormal v)
numberedTermLookup
  = mapFromList . zip [1..] . Map.elems $ builtinLookup

rtag :: Reference -> RTag
rtag r | Just x <- Map.lookup r builtinTypeNumbering = x
       | otherwise = error $ "rtag: unknown reference: " ++ show r


builtinTermNumbering :: Map Reference Word64
builtinTermNumbering
  = Map.fromList (zip (Map.keys $ builtinLookup @Symbol) [1..])

builtinTermBackref :: EnumMap Word64 Reference
builtinTermBackref
  = mapFromList . zip [1..] . Map.keys $ builtinLookup @Symbol

builtinTypeNumbering :: Map Reference RTag
builtinTypeNumbering = Map.fromList typeReferences

builtinTypeBackref :: EnumMap RTag Reference
builtinTypeBackref = mapFromList $ swap <$> typeReferences
  where swap (x, y) = (y, x)
