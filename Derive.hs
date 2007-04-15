
module Main(main) where

import System.Console.GetOpt
import System.Environment
import System.Directory
import System.Exit
import System.Cmd
import System.FilePath
import System.Random
import System.IO
import Control.Monad
import Data.Maybe
import Data.List
import Data.Char
import Data.Int


{-
WHAT TO DERIVE:

To derive something we must write:

data Foo = Foo
    deriving (Eq, Ord {-! Functor, Binary !-} )

Or if we don't want to derive other stuff:

data Foo = Foo
    deriving ({-! Binary !-})

The (brackets) must be present, commas in derive list are required only to separate elements, but are permitted before or after.

CONSOLE OPTIONS:

-o file, which file should the code go in - no file defaults to the console

-import, should an import statement be added

-module name, should a module statement be added, and if so with what name

-append, append the code to the current file (overrides all other flags)

And a list of files to execute upon

-}



data Flag = Version | Help | Output String | Import String | Module String
          | Append | Derive [String] | KeepTemp | NoOpts
            deriving (Eq, Show)


options :: [OptDescr Flag]
options =
 [ Option "v"  ["version"] (NoArg Version)          "show version number"
 , Option "h?" ["help"]    (NoArg Help)             "show help message"
 , Option "o"  ["output"]  (ReqArg Output "FILE")   "output FILE"
 , Option "i"  ["import"]  (OptArg (Import . fromMaybe "") "MODULE") "add an import statement"
 , Option "m"  ["module"]  (ReqArg Module "MODULE") "add a module MODULE where statement"
 , Option "a"  ["append"]  (NoArg Append)           "append the result to the file"
 , Option "d"  ["derive"]  (ReqArg split "DERIVES") "things to derive for all types"
 , Option "k"  ["keep"]    (NoArg KeepTemp)         "keep temporary file"
 , Option "n"  ["no-opts"] (NoArg NoOpts)           "ignore the file options"
 ]
 where
    split = Derive . words . map (\x -> if x == ',' then ' ' else x)


getOpts :: IO ([Flag], [String])
getOpts = do
    args <- getArgs
    case getOpt Permute options args of
        (o,n,[]  ) | Version `elem` o -> putStrLn "Derive 0.1, (C) Neil Mitchell & Stefan O'Rear 2006-2007" >> exitSuccess
                   | Help `elem` o    -> putStr useage >> exitSuccess
                   | null n           -> putStr ("no files specified\n" ++ useage) >> exitSuccess
                   | otherwise        -> return (o, n)
        (_,_,errs) -> putStr (concat errs ++ useage) >> exitFailure
    where
        useage = usageInfo "Usage: derive [OPTION...] files..." options
        exitSuccess = exitWith ExitSuccess


main = do
    (flags,files) <- getOpts
    files <- mapM pickFile files
    mapM_ (mainFile flags) (catMaybes files)
    when (any isNothing files) exitFailure


pickFile :: FilePath -> IO (Maybe FilePath)
pickFile orig = f [orig, orig <.> "hs", orig <.> "lhs"]
    where
        f [] = putStrLn ("Error, file not found: " ++ orig) >> return Nothing
        f (x:xs) = do
            b <- doesFileExist x
            if b then return $ Just x else f xs


appendMsg = "--------------------------------------------------------\n" ++
            "-- DERIVES GENERATED CODE\n" ++
            "-- DO NOT MODIFY BELOW THIS LINE\n" ++
            "-- CHECKSUM: "


-- delete the end of a file with the appendMsg and a correct hash
-- make sure there are at least 4 blank lines at the end
-- return True for warning
dropAppend :: String -> (String,Bool)
dropAppend xs = f 0 xs
    where
        f i xs | appendMsg `isPrefixOf` xs =
                if hashString rest == chk
                then f i []
                else (xs ++ "\n\n\n\n", True)
            where (chk, rest) = span isDigit $ drop (length appendMsg) xs

        f i [] = (replicate (4 - i) '\n', False)
        f i ('\n':xs) = add '\n' (f (i+1) xs)
        f i (x:xs) = add x (f 0 xs)

        add c ~(cs,b) = (c:cs,b)



mainFile flags file = do
    (fileflags,modname,datas,reqs) <- parseFile flags file
    let tmpfile = "Temp.hs"
    
        devs = ["'\\n': $( _derive_string_instance make" ++ cls ++ " ''" ++ ctor ++ " )"
               | (ctor,cls) <- reqs]

        hscode x = "{-# OPTIONS_GHC -fth -fglasgow-exts -w #-}\n" ++
                   "module " ++ modname ++ " where\n" ++
                   "import Data.DeriveTH\n" ++
                   concat [ "import Data.Derive." ++ cls ++ "\n" | (_, cls) <- reqs ] ++
                   datas ++ "\n" ++
                   "main = writeFile " ++ show x ++ " $\n" ++
                   "    unlines [" ++ concat (intersperse ", " devs) ++ "]\n"

    -- note: Wrong on Hugs on Windows
    tmpdir <- getTemporaryDirectory
    b <- doesDirectoryExist tmpdir
    tmpdir <- return $ if b then tmpdir else ""
    
    (hsfile, hshndl) <- openTempFileLocal tmpdir "Temp.hs"
    (txfile, txhndl) <- openTempFileLocal tmpdir "Temp.txt"
    hClose txhndl
    
    hPutStr hshndl $ hscode txfile
    hClose hshndl
    
    system $ "ghc -e " ++ modname ++ ".main " ++ hsfile

    txhndl <- openFile txfile ReadMode
    res <- hGetContents txhndl
    length res `seq` return ()
    hClose txhndl
    
    when (KeepTemp `notElem` flags) $ do
        removeFile hsfile
        removeFile txfile

    flags <- return $ fileflags ++ flags
    if Append `elem` flags then do
        src <- readFile file
        let (src2,b) = dropAppend src
        when b $ putStrLn "Warning, Checksum does not match, please edit the file manually"
        writeFile file $ src2 ++ (if null res then "" else appendMsg ++ hashString res ++ "\n" ++ res)
     else do
        let modline = concat $ take 1 ["module " ++ x ++ " where\n" | Module x <- flags]
            impline = unlines ["import " ++ if null i then modname else i | Import i <- flags]
            answer = modline ++ impline ++ res
        
        case [x | Output x <- flags] of
             [] -> putStr answer
             (x:_) -> writeFile x answer


-- return the flags, a string that is the data structures only (including Typeable, Data)
-- and a set of derivation names with types

-- first disguard blank lines and lines which are -- comments
-- next find all lines which start a section, i.e. have something in column 0
-- group lines so every line starts at column 1
-- look for newtype, data etc.
-- look for deriving
parseFile :: [Flag] -> FilePath -> IO ([Flag], String, String, [(String,String)])
parseFile flags file = do
        src <- liftM lines $ readFile file
        options <- if NoOpts `elem` flags then return [] else parseOptions src
        modname <- parseModname src
        let deriv = concat [x | Derive x <- flags ++ options]
        (decl,req) <- return $ unzip $ concatMap (checkData deriv) $ joinLines $
                               map dropComments $ filter (not . isBlank) src
        return (options, modname, unlines decl, concat req)
    where
        parseOptions (x:xs)
            | "{-# OPTIONS_DERIVE " `isPrefixOf` x = do
                    a <- readOptions $ takeWhile (/= '#') $ drop 19 x
                    b <- parseOptions xs
                    return $ a ++ b
            | "{-# OPTIONS" `isPrefixOf` x = parseOptions xs
        parseOptions _ = return []
        
        readOptions x = case getOpt Permute options (words x) of
                            (a,_,ns) -> mapM_ putStr ns >> return a


        parseModname (x:xs) | "module " `isPrefixOf` x = return $ takeWhile f $ dropWhile isSpace $ drop 6 x
            where f x = not (isSpace x) && x `notElem` "("
        parseModname (x:xs) = parseModname xs
        parseModname [] = putStrLn "Error, module name not detected" >> return "Main"


        isBlank x = null x2 || "--" `isPrefixOf` x2
            where x2 = dropWhile isSpace x
            
        dropComments ('-':'-':xs) = []
        dropComments (x:xs) = x : dropComments xs
        dropComments [] = []

        joinLines (x1:x2:xs) | col1 x1 && not (col1 x2) = joinLines ((x1 ++ x2) : xs)
            where col1 = null . takeWhile isSpace
        joinLines (x:xs) = x : joinLines xs
        joinLines [] = []
        
        checkData extra x
                | keyword `elem` ["data","newtype"] = [(x, map ((,) name) req)]
                | keyword `elem` ["type","import"] = [(x,[])]
                | otherwise = []
            where
                keyword = takeWhile (not . isSpace) x
                name = parseName $ drop (length keyword) x
                req = nub $ extra ++ parseDeriving x


        -- which derivings have been requested
        -- find all things inside {-! !-} and 'words' them
        parseDeriving :: String -> [String]
        parseDeriving x = words $ f False x
            where
                f b ('{':'-':'!':xs) = ' ' : f True  xs
                f b ('!':'-':'}':xs) = ' ' : f False xs
                f b (x:xs) = [if x == ',' then ' ' else x | b] ++ f b xs
                f b [] = []


        -- if there is a =>, its just after that
        -- if there isn't, then its right now
        -- if the => is after =, then ignore
        parseName x = if "=>" `isPrefixOf` b
                      then parseName (drop 2 b)
                      else head (words a)
            where (a,b) = break (== '=') x


hashString :: String -> String
hashString = show . abs . foldl f 0 . filter (not . isSpace)
    where
        f :: Int32 -> Char -> Int32
        f x y = x * 31 + fromIntegral (ord y)


-- Note: openTempFile is not available on Hugs, which sucks
openTempFileLocal :: FilePath -> String -> IO (FilePath, Handle)
openTempFileLocal dir template = do
    i <- randomRIO (1000::Int,9999)
    let (file,ext) = splitExtension template
        s = dir </> (file ++ show i) <.> ext
    b <- doesFileExist s
    if b then openTempFileLocal dir template else do
        h <- openFile s ReadWriteMode
        return (s, h)
