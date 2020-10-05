------------------------------------------------------------------------------
--- Compute infos about all `HtmlFormDef` operations occurring in a module
--- and transform FlatCurry programs by setting correct form IDs, if
--- necessary.
---
--- @author Michael Hanus
--- @version September 2020
------------------------------------------------------------------------------

module C2C.ExtractForms ( extractFormsInProg )
 where

import Directory    ( doesFileExist, getModificationTime, removeFile )
import FilePath     ( (</>), (<.>) )
import IO           ( hGetContents, openFile, IOMode(..) )
import List         ( intercalate, partition )
import System       ( exitWith, getArgs, getPID, system )

import AbstractCurry.Files
import AbstractCurry.Select
import AbstractCurry.Types
import System.CurryPath    ( inCurrySubdir, lookupModuleSourceInLoadPath )

import C2C.Options
import C2C.TransFlatCurryForms      ( setFormIDsInFlatCurry )
import C2C.TransTypedFlatCurryForms ( setFormIDsInTypedFlatCurry )

-- The cache file for storing qualified form names of a module w.r.t.
-- a directory.
formCacheFile :: String -> String -> String
formCacheFile mdir mname = inCurrySubdir (mdir </> mname) <.> "htmlforms"

--- Extract and check all forms defined in a Curry module.
--- Returns the qualified names of the exported forms as the second component.
--- The first component is `Nothing` when the module was not transformed
--- to attach form ids, otherwise it is `Just` the module name.
extractFormsInProg :: Options -> String -> IO (Maybe String, [QName])
extractFormsInProg opts mname =
  lookupModuleSourceInLoadPath mname >>=
  maybe (error $ "Module '" ++ mname ++ "' not found in load path!")
        extractWithFormCache
 where
  extractWithFormCache (mdir,mfile) = do
    let formfile = formCacheFile mdir mname
    ffexists <- doesFileExist formfile
    if not ffexists
      then readFormsInProg opts mname formfile
      else do
        ctime <- getModificationTime mfile
        ftime <- getModificationTime formfile
        if ctime > ftime
          then readFormsInProg opts mname formfile
          else do
            putStrLnInter opts $ "Reading file '" ++ formfile ++ "'"
            ffcont <- openFile formfile ReadMode >>= hGetContents
            case reads ffcont of
              [(t,"")] -> return t
              _        -> do
                putStrLnInfo opts $
                  "WARNING: removing broken form info file '" ++ formfile ++ "'"
                removeFile formfile
                extractWithFormCache (mdir,mfile)

readFormsInProg :: Options -> String -> String -> IO (Maybe String, [QName])
readFormsInProg opts mname formfile = do
  putStrLnInfo opts $
    "Extracting and checking forms contained in module '" ++ mname ++ "'..."
  when (optVerb opts > 1) $ putStr $ "Reading module '" ++ mname ++ "'..."
  cprog <- readCurry mname
  putStrLnInter opts "done!"
  let (formnames,privatenames) = extractFormOps cprog
  unless (null privatenames) $ putStrLn $
    "WARNING: Private form operations found (and not translated):\n" ++
    unwords (map snd privatenames)
  unless (null formnames) $ putStrLnInfo opts $
    "Form operations found: " ++ unwords (map snd formnames)
  checkFormElemCallsInProg opts formnames cprog 
  mbtrans <- if null formnames
               then return Nothing
               else checkFormIDsInProg opts mname formnames
  putStrLnInter opts $ "Writing form names to '" ++ formfile ++ "'"
  -- store form names in form cache file:
  catch (writeFile formfile (show (mbtrans, formnames))) (const done)
  return (mbtrans, formnames)

--- Extract public and private form definitions from a program.
extractFormOps :: CurryProg -> ([QName], [QName])
extractFormOps prog =
  let (fds1,fds2) = partition (\fd -> funcVis fd == Public)
                              (filter hasFormDefType (functions prog))
  in (map funcName fds1, map funcName fds2)
 where
  hasFormDefType fdecl = case typeOfQualType (funcType fdecl) of
    CTApply (CTCons tc) _ -> tc == formDefTypeName
    _                     -> False


------------------------------------------------------------------------------
-- Check whether all `HTML.Base.formElem` calls are applied to
-- top-level public form definitions.
-- The second argument is the list of public form definitions of the
-- current module.
checkFormElemCallsInProg :: Options -> [QName] -> CurryProg -> IO ()
checkFormElemCallsInProg opts formnames prog = do
  let mname  = progName prog
      fdecls = functions prog
      errfuncs = concatMap (checkFormElemCallsInFunc opts formnames mname)
                           fdecls
  unless (null errfuncs) $ do
    putStrLn $ "ERROR: Illegal use of 'HTML.Base.formElem' in function: " ++
               unwords (map snd errfuncs)
    exitWith 1

checkFormElemCallsInFunc :: Options -> [QName] -> String -> CFuncDecl -> [QName]
checkFormElemCallsInFunc opts formnames mname fdecl =
  concatMap checkRule (funcRules fdecl)
 where
  checkRule (CRule _ rhs) = checkRhs rhs

  checkRhs (CSimpleRhs rhs ldecls) = checkExp rhs ++ concatMap checkLDecl ldecls
  checkRhs (CGuardedRhs gs ldecls) = 
    concatMap (\ (g,e) -> checkExp g ++ checkExp e) gs ++
    concatMap checkLDecl ldecls

  checkExp (CVar _)            = []
  checkExp (CLit _)            = []
  checkExp (CSymbol _)         = []
  checkExp (CApply e1 e2)      = checkApply e1 e2
  checkExp (CLambda _ le)      = checkExp le
  checkExp (CLetDecl ld le)    = concatMap checkLDecl ld ++ checkExp le
  checkExp (CDoExpr sl)        = concatMap checkStat sl
  checkExp (CListComp le sl)   = checkExp le ++ concatMap checkStat sl
  checkExp (CCase _ ce bl)     =
    checkExp ce ++ concatMap (\ (_,rhs) -> checkRhs rhs) bl
  checkExp (CTyped te _)       = checkExp te
  checkExp (CRecConstr _ upds) = concatMap (checkExp . snd) upds
  checkExp (CRecUpdate e upds) = checkExp e ++ concatMap (checkExp . snd) upds

  checkApply e1 e2 = case (e1,e2) of
    (CSymbol f1, CSymbol f2)  -> if f1 /= hfe || fst f2 /= mname ||
                                    f2 `elem` formnames
                                   then []
                                   else [funcName fdecl]
    (CSymbol f, _) | f == hfe -> [funcName fdecl]
    _                         -> checkExp e1 ++ checkExp e2
   where hfe = ("HTML.Base","formElem")

  checkStat (CSExpr e)  = checkExp e
  checkStat (CSPat _ e) = checkExp e
  checkStat (CSLet ld)  = concatMap checkLDecl ld
  
  checkLDecl (CLocalFunc f)    = concatMap checkRule (funcRules f)
  checkLDecl (CLocalPat _ rhs) = checkRhs rhs
  checkLDecl (CLocalVars _)    = []

------------------------------------------------------------------------------
-- Test whether all `HtmlFormDef` identifiers in a module are correct,
-- i.e., are identical to the string representation of their defining
-- operations. If there are some differences, transform the
-- (Typed) FlatCurry file (depending on the Curry system).
-- The result is `Nothing` when nothing is transformed, otherwise
-- it is `Just` the module name.
checkFormIDsInProg :: Options -> String -> [QName] -> IO (Maybe String)
checkFormIDsInProg opts mname formnames = do
  fidok <- testFormIDsInProg opts mname formnames
  if fidok
    then return Nothing
    else do
      putStrLnInfo opts $
        "Some forms have non-matching IDs: setting correct form IDs..."
      case optSysName opts of
        "pakcs" -> setFormIDsInFlatCurry opts mname
        "kics2" -> setFormIDsInTypedFlatCurry opts mname
        o       -> do putStrLn $ "Unknown Curry system '" ++ o ++ "'. " ++
                                 "Cannot set correct form IDs!"
                      exitWith 1
      return (Just mname)

-- Test whether all `HtmlFormDef` identifiers in a module are correct,
-- i.e., are identical to the string representation of their defining
-- operations.
testFormIDsInProg :: Options -> String -> [QName] -> IO Bool
testFormIDsInProg opts mname formnames = do
  pid <- getPID
  let testprogname = "TESTFORMPROG_" ++ show pid
  putStrLnInter opts $ "Generating check program '" ++ testprogname ++ "':"
  let testprog = unlines
        [ "import " ++ mname
        , "import HTML.Base"
        , "import System ( exitWith )"
        , ""
        , checkFormIDDefinition
        , ""
        , "main :: IO ()"
        , "main = do"
        , "  results <- sequence [" ++
                    intercalate "," (map genFormCall formnames) ++ "]"
        , "  unless (and results) (exitWith 1)"
        ]
  writeFile (testprogname ++ ".curry") testprog
  putStrLnDetail opts testprog
  putStrLnInter opts $ "Executing check program '" ++ testprogname ++ "'..."
  c <- system $ unwords
         [optSystem opts </> "bin" </> "curry",":set v0", ":load", testprogname,
          ":eval", "main", ":quit"]
  cleanProg testprogname
  return $ c == 0
 where
  cleanProg modname = do
    system $ unwords [optSystem opts </> "bin" </> "cleancurry", modname]
    system $ "/bin/rm -f " ++ modname ++ ".curry"

  genFormCall qn =
    let s = showQName qn
    in "checkFormID (" ++ s ++ ",\"" ++ s ++ "\")"

checkFormIDDefinition :: String
checkFormIDDefinition = unlines
 ["checkFormID :: (HtmlFormDef a, String) -> IO Bool"
 ,"checkFormID (fd, s) ="
 ,"  if (formDefId fd == s)"
 ,"    then return True"
 ,"    else do"
 ,"      putStrLn (\"Warning: Form definition '\" ++ s ++ \"' has non-matching ID\")"
 ,"      return False"
 ]

{-
------------------------------------------------------------------------------
--- Auxiliary definitions used by the form checker.
------------------------------------------------------------------------------

import System ( exitWith )
import HTML.Base

checkFormID :: (HtmlFormDef a, String) -> IO Bool
checkFormID (fd, s) =
  if (formDefId fd == s)
    then return True
    else do
      putStrLn $ "Warning: Form definition '" ++ s ++ "' has non-matching ID."
      return False

-}

------------------------------------------------------------------------------