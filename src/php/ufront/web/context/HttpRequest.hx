/**
 * ...
 * @author Franco Ponticelli
 */

package php.ufront.web.context;

import haxe.io.Bytes;
import thx.sys.Lib;
import ufront.web.upload.*;
import ufront.web.context.HttpRequest.OnPartCallback;
import ufront.web.context.HttpRequest.OnDataCallback;
import ufront.web.context.HttpRequest.OnEndPartCallback;
import ufront.web.UserAgent;
import ufront.core.MultiValueMap;
import haxe.ds.StringMap;
import ufront.core.Sync;
using tink.CoreApi;
using Strings;
using StringTools;

class HttpRequest extends ufront.web.context.HttpRequest
{
	public static function encodeName(s:String)
	{
		return s.urlEncode().replace('.', '%2E');
	}
	
	public function new()
	{
		_parsed = false;
	}
	
	override function get_queryString()
	{
		if (null == queryString)
			queryString = untyped __var__('_SERVER', 'QUERY_STRING');
		return queryString;
	}
	
	override function get_postString()
	{
		if (httpMethod == "GET")
			return "";
		if (null == postString)
		{
			if (untyped __call__("isset", __var__('GLOBALS', 'HTTP_RAW_POST_DATA')))
			{
				postString = untyped __var__('GLOBALS', 'HTTP_RAW_POST_DATA');
			} else {
				postString = untyped __call__("file_get_contents", "php://input");
			}
			if (null == postString)
				postString = "";
		}
		return postString;
	}
	
	var _parsed:Bool;

	override public function parseMultipart( ?onPart:OnPartCallback, ?onData:OnDataCallback, ?onEndPart:OnEndPartCallback ):Surprise<Noise,Error>
	{
		if (_parsed) return throw new Error('parseMultipart() can only been called once');
		_parsed = true;

		var post = get_post();
		if( untyped __call__("isset", __php__("$_FILES")) ) {

			var parts:Array<String> = untyped __call__("new _hx_array",__call__("array_keys", __php__("$_FILES")));
			var errors = [];
			var allPartFutures = [];

			if ( onPart==null ) onPart = function(_,_) return Sync.of( Success(Noise) );
			if ( onData==null ) onData = function(_,_,_) return Sync.of( Success(Noise) );
			if ( onEndPart==null ) onEndPart = function() return Sync.of( Success(Noise) );

			for(part in parts) {
				// Extract the info from PHP's $_FILES
				var info:Dynamic = untyped __php__("$_FILES[$part]");
				var file:String = untyped info['name'];
				var tmp:String = untyped info['tmp_name'];
				var name = StringTools.urlDecode(part);
				if (tmp == '') continue;
				
				// Handle any errors
				var err:Int = untyped info['error'];
				if(err > 0) {
					switch(err) {
						case 1: 
							var maxSize = untyped __call__('ini_get', 'upload_max_filesize');
							errors.push('The uploaded file exceeds the max size of $maxSize');
						case 2: 
							var maxSize = untyped __call__('ini_get', 'post_max_size');
							errors.push('The uploaded file exceeds the max file size directive specified in the HTML form (max is $maxSize)');
						case 3: errors.push('The uploaded file was only partially uploaded');
						case 4: // No file was uploaded
						case 6: errors.push('Missing a temporary folder');
						case 7: errors.push('Failed to write file to disk');
						case 8: errors.push('File upload stopped by extension');
					}
					continue;
				}

				// Prepare for parsing the file
				var fileResource:Dynamic = null;
				var bsize = 8192;
				var currentPos = 0;
				var partFinishedTrigger = Future.trigger();
				allPartFutures.push( partFinishedTrigger.asFuture() );

				// Helper function for processing the results of our callback functions.
				function processResult( surprise:Surprise<Noise,Error>, andThen:Void->Void ) {
					surprise.handle( function(outcome) {
						switch outcome {
							case Success(err): 
								andThen();
							case Failure(err): 
								errors.push( err.toString() );
								try untyped __call__("fclose", fileResource) catch (e:Dynamic) errors.push( 'Failed to close upload tmp file: $e' );
								try untyped __call__("unlink", tmp) catch (e:Dynamic) errors.push( 'Failed to delete upload tmp file: $e' );
								partFinishedTrigger.trigger( outcome );
						}
					});
				}

				// Function to read chunks of the file, and close when done
				function readNextPart() {
					if ( false==untyped __call__("feof", fileResource) ) {
						// Read this line, call onData, and then read the next part
						var buf:String = untyped __call__("fread", fileResource, bsize);
						var size:Int = untyped __call__("strlen", buf);
						processResult( onData(Bytes.ofString(buf),currentPos,size), function() readNextPart() );
						currentPos += size;
					}
					else {
						// close the file, call onEndPart(), and delete the temp file
						untyped __call__("fclose", fileResource);
						processResult( onEndPart(), function() untyped __call__("unlink",tmp) );
					}
				}

				// Call `onPart`, then open the file, then start reading
				processResult( onPart(name,file), function() {
					fileResource = untyped __call__("fopen", tmp, "r");
					readNextPart();
				});
			}

			return Future.ofMany( allPartFutures ).map( function(_) {
				if ( errors.length==0 ) return Success(Noise);
				else return Failure(Error.withData('Error parsing multipart request data', errors));
			});
		}
		else return Sync.of( Success(Noise) );
	}
	
	override function get_query()
	{
		if (null == query)
		{
			query = getHashFromString(queryString);
		}
		return query;
	}
	
	override function get_post()
	{
		if (httpMethod == "GET")
			return new MultiValueMap();
		if (null == post)
		{
			if ( "multipart/form-data"==clientHeaders.get("ContentType") ) {
				post = new MultiValueMap();
				if (untyped __call__("isset", __php__("$_POST")))
				{
					var postNames:Array<String> = untyped __call__( "new _hx_array",__call("array_keys", __php__("$_POST" )));

					for ( name in postNames ) {
						var val:Dynamic = untyped __php__("$_POST[$name]");
						if ( untyped __call__("is_array", val) ) {
							// For each value in the array, add it to our post object.
							var h = php.Lib.hashOfAssociativeArray( val );
							for ( k in h.keys() ) {
								if ( untyped __call__("is_string", val) )
									post.add( k, h.get(k) );
								// else: Note that we could try recurse here if there's another array, but for now I'm 
								// giving ufront a rule: only single level `fruit[]` type input arrays are supported,
								// any recursion goes beyond this, so let's not bother.
							}
						}
						else if ( untyped __call__("is_string", val) ) {
							post.add( name, cast val );
						}
					}
				}
			}
			else {
				post = getHashFromString(postString);
			}

			if (untyped __call__("isset", __php__("$_FILES")))
			{
				var parts:Array<String> = untyped __call__("new _hx_array",__call__("array_keys", __php__("$_FILES")));
				untyped for (part in parts) {
					var file:String = __php__("$_FILES[$part]['name']");
					var name = StringTools.urldecode(part);
					post.add(name, file);
				}
			}
		}
		return post;
	}
	
	override function get_cookies()
	{
		if (null == cookies)
			cookies = Lib.hashOfAssociativeArray(untyped __php__("$_COOKIE"));
		return cookies;
	}
	
	override function get_userAgent()
	{
		if (null == userAgent)
			userAgent = UserAgent.fromString(clientHeaders.get("User-Agent"));
		return userAgent;
	}
	
	override function get_hostName()
	{
		if (null == hostName)
			hostName = untyped __php__("$_SERVER['SERVER_NAME']");
		return hostName;
	}
	
	override function get_clientIP()
	{
		if (null == clientIP)
			clientIP = untyped __php__("$_SERVER['REMOTE_ADDR']");
		return clientIP;
	}
	
	override function get_uri()
	{
		if (null == uri)
		{
			var s:String = untyped __php__("$_SERVER['REQUEST_URI']");
			uri = s.split("?")[0];
		}
		return uri;
	}
	
	override function get_clientHeaders()
	{
		if (null == clientHeaders)
		{
			clientHeaders = new MultiValueMap();
			var h = Lib.hashOfAssociativeArray(untyped __php__("$_SERVER"));
			for(k in h.keys()) {
				if(k.substr(0,5) == "HTTP_") {
					clientHeaders.add(k.substr(5).toLowerCase().replace("_", "-").ucwords(), h.get(k));
				}
			}
			if (h.exists("CONTENT_TYPE"))
				clientHeaders.set("Content-Type", h.get("CONTENT_TYPE"));
		}
		return clientHeaders;
	}
	
	override function get_httpMethod()
	{
		if (null == httpMethod)
		{
			untyped if(__php__("isset($_SERVER['REQUEST_METHOD'])"))
				httpMethod =  __php__("$_SERVER['REQUEST_METHOD']");
			if (null == httpMethod) httpMethod = "";
		}
		return httpMethod;
	}
	
	override function get_scriptDirectory()
	{
		if (null == scriptDirectory)
		{
			scriptDirectory =  untyped __php__("dirname($_SERVER['SCRIPT_FILENAME'])") + "/";
		}
		return scriptDirectory;
	}
	
	override function get_authorization()
	{
		if (null == authorization)
		{
			authorization = { user:null, pass:null };
			untyped if(__php__("isset($_SERVER['PHP_AUTH_USER'])"))
			{
				authorization.user = __php__("$_SERVER['PHP_AUTH_USER']");
				authorization.pass = __php__("$_SERVER['PHP_AUTH_PW']");
			}
		}
		return authorization;
	}
	
	static var paramPattern = ~/^([^=]+)=(.*?)$/;
	static function getHashFromString(s:String):MultiValueMap<String>
	{
		var qm = new MultiValueMap();
		for (part in s.split("&"))
		{
			if (!paramPattern.match(part))
				continue;
			qm.add(
				StringTools.urlDecode(paramPattern.matched(1)),
				StringTools.urlDecode(paramPattern.matched(2)));
		}
		return qm;
	}
	
	static function getHashFrom(a:php.NativeArray)
	{
		if(untyped __call__("get_magic_quotes_gpc"))
			untyped __php__("reset($a); while(list($k, $v) = each($a)) $a[$k] = stripslashes((string)$v)");
		return Lib.hashOfAssociativeArray(a);
	}
}