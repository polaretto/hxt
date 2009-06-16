-- ------------------------------------------------------------

{- |
   Module     : Text.XML.HXT.IO.GetHTTPLibCurl
   Copyright  : Copyright (C) 2008 Uwe Schmidt
   License    : MIT

   Maintainer : Uwe Schmidt (uwe@fh-wedel.de)
   Stability  : stable
   Portability: portable

   GET for http access with libcurl

-}

-- ------------------------------------------------------------

module Text.XML.HXT.IO.GetHTTPLibCurl
    ( getCont
    )

where

import Control.Arrow			( first
					, (>>>)
					)
import Control.Concurrent.MVar
import Control.Monad			( when )

import Data.Char			( isDigit
					, isSpace
					)
import Data.List			( isPrefixOf )

import Network.Curl

import System.IO
import System.IO.Unsafe			( unsafePerformIO )

import Text.ParserCombinators.Parsec	( parse )

import Text.XML.HXT.DOM.Util		( stringToLower )
import Text.XML.HXT.DOM.XmlKeywords
import Text.XML.HXT.DOM.XmlOptions	( isTrueValue )

import Text.XML.HXT.Parser.ProtocolHandlerUtil
					( parseContentType )
import Text.XML.HXT.Version

-- ------------------------------------------------------------
--
-- the global flag for initializing curl in the 1. call

isInitCurl	:: MVar Bool
isInitCurl	= unsafePerformIO $ newMVar False

initCurl	:: IO ()
initCurl
    = do
      i <- takeMVar isInitCurl
      when (not i) ( do
		     curl_global_init 3
		     return ()
		   )
      putMVar isInitCurl True

-- ------------------------------------------------------------

--
-- the http protocol handler implemented by calling libcurl
-- (<http://curl.haxx.se/>)
-- via the curl binding
-- <http://hackage.haskell.org/cgi-bin/hackage-scripts/package/curl>
-- This function tries to support mostly all curl options concerning HTTP requests.
-- The naming convetion is as follows: A curl option must be prefixed by the string
-- \"curl\" and then written exactly as described in the curl man page
-- (<http://curl.haxx.se/docs/manpage.html>).
--
-- Example:
--
-- > getCont [("curl--user-agent","My first HXT app"),("curl-e","http://the.referer.url/")] "http://..."
--
-- will set the user agent and the referer URL for this request.

getCont		:: [(String, String)] -> String -> IO (Either ([(String, String)], String)
						              ([(String, String)], String))
getCont options uri
    = do
      initCurl
      resp <- curlGetResponse uri curlOptions
      -- dumpResponse
      return $ evalResponse resp
    where
    _dumpResponse r
	= do
	  hPutStrLn stderr $ show $ respCurlCode   r
	  hPutStrLn stderr $ show $ respStatus     r
	  hPutStrLn stderr $        respStatusLine r
	  hPutStrLn stderr $ show $ respHeaders    r
	  hPutStrLn stderr $        respBody       r

    curlOptions
	= defaultOptions ++ concatMap (uncurry copt) options ++ standardOptions

    defaultOptions						-- these options may be overwritten
	= [ CurlUserAgent ("hxt/" ++ hxt_version ++ " via libcurl")
	  , CurlFollowLocation True
	  ]

    standardOptions						-- these options can't be overwritten
	= [ CurlFailOnError    False
	  , CurlHeader         False
	  , CurlNoProgress     True
	  ]
    evalResponse r
	| rc /= CurlOK
	    = Left ( [ mkH transferStatus    "999"
		     , mkH transferMessage $ "curl library rc: " ++ show rc
		     ]
		   , "curl library error when requesting URI "
		     ++ show uri
		     ++ ": (curl return code=" ++ show rc ++ ") "
		   )
	| rs < 200 && rs >= 300
	    = Left ( contentT rsh ++ headers
		   , "http error when accessing URI "
		     ++ show uri
		     ++ ": "
		     ++ show rsl
		   )
	| otherwise
	    = Right ( contentT rsh ++ headers, respBody r
		    )
	where
	mkH x y	= (x, dropWhile isSpace y)

	headers
	    = map (\ (k, v) -> mkH (httpPrefix ++ k) v) rsh
	      ++
              statusLine (words rsl)

	contentT
	    = map (first stringToLower)			-- all header names to lowercase
	      >>>
	      filter ((== "content-type") . fst)	-- select content-type header
	      >>>
	      reverse					-- when libcurl is called with automatic redirects, there are more than one content-type headers
	      >>>
	      take 1					-- take the last one, (if at leat one is found)
	      >>>
	      map snd					-- select content-type value
	      >>>
	      map ( either (const []) id
		    . parse parseContentType ""		-- parse the content-type for mimetype and charset
		  )
	      >>>
	      concat

	statusLine (vers : _code : msg)			-- the status line of the curl response can be an old one, e.g. in the case of a redirect,
	    = [ mkH transferVersion   vers		-- so the return code is taken from the status field, which is contains the last status
	      , mkH transferMessage $ unwords msg
	      , mkH transferStatus  $ show rs
	      ]
        statusLine _
	    = []

	rc  = respCurlCode    r
	rs  = respStatus      r
	rsl = respStatusLine  r
	rsh = respHeaders     r

-- ------------------------------------------------------------

copt	:: String -> String -> [CurlOption]
copt k v
    | "curl" `isPrefixOf` k
	= opt2copt (drop 4 k) v

    | k == a_proxy
	= opt2copt k v

    | k == a_options_curl
	= curlOptionString v

    | otherwise
	= []

opt2copt	:: String -> String -> [CurlOption]
opt2copt k v
    | k `elem` ["-A", "--user-agent"]	= [CurlUserAgent v]
    | k `elem` ["-b", "--cookie"]	= [CurlCookie v]
    | k == "--connect-timeout"
      &&
      isIntArg v			= [CurlConnectTimeout      $ read    v]
    | k == "--crlf"			= [CurlCRLF                $ isTrue  v]
    | k `elem` ["-d", "--data"]		= [CurlPostFields          $ lines   v]
    | k `elem` ["-e", "--referer"]	= [CurlReferer                       v]
    | k `elem` ["-H", "--header"]	= [CurlHttpHeaders         $ lines   v]
    | k == "--ignore-content-length"	= [CurlIgnoreContentLength $ isTrue  v]
    | k `elem` ["-I", "--head"]		= [CurlNoBody              $ isTrue  v]
    | k `elem` ["-L", "--location"]	= [CurlFollowLocation      $ isTrue  v]
    | k == "--max-filesize"
      &&
      isIntArg v			= [CurlMaxFileSizeLarge    $ read    v]
    | k `elem` ["-m", "--max-time"]
      &&
      isIntArg v			= [CurlTimeoutMS           $ read    v]
    | k `elem` ["-n", "--netrc"]	= [CurlNetrcFile                     v]
    | k `elem` ["-R", "--remote-time"]  = [CurlFiletime            $ isTrue  v]
    | k `elem` ["-u", "--user"]		= [CurlUserPwd                       v]
    | k `elem` ["-U", "--proxy-user"]	= [CurlProxyUserPwd                  v]
    | k `elem` ["-x", "--proxy"]        =  proxyOptions
    | k `elem` ["-X", "--request"]      = [CurlCustomRequest                 v]
    | k `elem` ["-y", "--speed-time"]
      &&
      isIntArg v                        = [CurlLowSpeedTime        $ read    v]
    | k `elem` ["-Y", "--speed-limit"]
      &&
      isIntArg v			= [CurlLowSpeed            $ read    v]
    | k `elem` ["-z", "--time-cond"]	=  ifModifiedOptions
    | k == "--max-redirs"
      &&
      isIntArg v			= [CurlMaxRedirs           $ read    v]
    | k `elem` ["-0", "--http1.0"]	= [CurlHttpVersion       HttpVersion10]
    | otherwise				= []
    where
    ifModifiedOptions
	| "-" `isPrefixOf` v
	  &&
	  isIntArg v'			= [CurlTimeCondition TimeCondIfUnmodSince
					  ,CurlTimeValue           $ read   v'
					  ]
	| isIntArg v			= [CurlTimeCondition TimeCondIfModSince
					  ,CurlTimeValue           $ read   v'
					  ]
	| otherwise			= []
	where
	v' = tail v

    proxyOptions
	= [ CurlProxyPort pport
	  , CurlProxy     phost
	  ]
	where
	pport
	    | isIntArg ppp	= read v
	    | otherwise		= 1080
	(phost, pp) 		= span (/=':') v
	ppp      		= drop 1 pp



isTrue		:: String -> Bool
isTrue s  	= null s || isTrueValue s

isIntArg	:: String -> Bool
isIntArg s 	= not (null s) && all isDigit s

curlOptionString	:: String -> [CurlOption]
curlOptionString
    = concatMap (uncurry copt) . opts . words
    where
    opts l
	| null l			= []
	| not ("-" `isPrefixOf` k)	= opts l1		-- k not an option: ignore
	| null l1			= opts (k:"":l1)	-- last option
	| "-" `isPrefixOf` v		= (k, "") : opts (v:l)	-- k option without arg
	| otherwise			= (k, v) : opts l2	-- k with value
	where
	(k:l1) = l
	(v:l2) = l1

-- ------------------------------------------------------------
