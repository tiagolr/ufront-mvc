package ufront.web.mvc;     
import php.Lib;
import sb.controller.backend.SetupController;
import thx.error.Error;
import thx.html.HtmlFormat;
import thx.html.XHtmlFormat;
import thx.html.HtmlParser;
import thx.html.HtmlDocumentFormat;
import ufront.web.UserAgent;
using StringTools;
using thx.collections.UArray;

// add script
// add styleSheets
// add meta
// add head link
// add IE only scripts
// add IE only styleSheets
// html tag should not increment level
// DOCTYPE should be lowercase
// remove extra Newlines
// add favicon
// fix doctype parsing for XHtml 
// add chrome compatibility

// add agent specific things:
//	- IE only tags
//	- viewport <meta name="viewport" content="width=device-width; initial-scale=1.0; maximum-scale=1.0;">
//	- equivalences: <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
//					<meta charset="utf-8">

class HtmlViewResult extends ViewResult
{
	public var version : HtmlVersion;
	public var charset(getCharset, setCharset) : String;
	public var language(getLanguage, setLanguage) : String;
	public var autoformat : Bool;
	public var title(getTitle, setTitle) : String;
	public var agentSensitiveOutput : Bool;
	
	var _scripts : Array<Script>;
	var _styleSheets : Array<StyleSheet>;
	var _agent : UserAgent;
	
	public function new(?data : Hash<Dynamic>, ?version : HtmlVersion, language = "en", charset = "UTF-8")
	{
		super(data);
		this.version = null == version ? Html5 : version;
		this.language = language;
		this.charset = charset;
		this.autoformat = true;
		this.agentSensitiveOutput = true;
		_scripts = [];
		_styleSheets = [];
	}
	
	override function executeResult(context : ControllerContext)
	{
		_agent = context.request.userAgent;
		if (context.response.contentType == "text/html")
			context.response.contentType = getContentType(version);
		super.executeResult(context);
	}
	
	override function writeResponse(context : ControllerContext, content : String)
	{
		var template = getTemplate(version);
		var result : String = null;
		var parser = getParser(version);
		if(autoformat)
		{
			var body = template.replace("{content}", content);
			var dom = parser(body);
			handleDom(dom, context);
			result = getFormatter(version).format(dom);
		} else {
			var dom = parser(template);
			handleDom(dom, context);
			result = getFormatter(version).format(dom);
			result = result.replace("{content}", content);
		}
		context.response.write(result);
	}
	
	function handleDom(dom : Xml, context : ControllerContext)
	{       
		var html  = dom.firstElement();
		var head  = html.firstElement();
		var body  = head.elementsNamed("body").next();
		var title = head.elementsNamed("title").next();  
		
		// title
		var t = getTitle();
		if(null != t)
			title.addChild(Xml.createPCData(t));
		
		// language
		var l = getLanguage();
		if(null != l)
		{
			html.set("lang", l);
			switch(version)
			{
				case XHtml10Transitional, XHtml10Frameset, XHtml10Strict, XHtml11: 
					html.set("xml:lang", l);
				default:
				//
			}
		}
		
		// encoding
		var c = getCharset();
		if(null != c)
		{
		 	switch(version)
			{
				case Html401Strict, Html401Transitional, Html401Frameset, XHtml10Transitional, XHtml10Frameset, XHtml10Strict, XHtml11:
                	var meta = Xml.createElement("meta");
					meta.set("http-equiv", "content-type");
 					meta.set("content", "text/html; charset=" + c);
					head.insertChild(meta, 0);
				case Html5:
					var meta = Xml.createElement("meta");
					meta.set("charset", c);
					head.insertChild(meta, 0);
			}   
		}
		
		// scripts
		var scripts = getScripts();
		for (script in scripts)
		{
			var node = Xml.createElement("script");
			if (null != script.src)
			{
				node.set("src", script.src);
			} else {
				var content = Xml.createPCData(script.script);
				node.addChild(content);
			}
			if (true == script.defer)
				node.set("defer", "defer");
			if (null != script.charset)
				node.set("charset", script.charset);
			node.set("type", "text/javascript");
			conditionallyWrapNode(head, node, script.browser);
		}

		// styleSheets 
		var styleSheets = getStyleSheets();
		for (css in styleSheets)
		{
			var node : Xml;
			if (null != css.href)
			{
				node = Xml.createElement("link");
				node.set("href", css.href);
				node.set("rel", null == css.rel ? "StyleSheet" : css.rel);
				if (null != css.title)
					node.set("title", css.title);
				if (null != css.charset)
					node.set("charset", css.charset);
			} else {
				node = Xml.createElement("style");
				var content = Xml.createPCData(css.style);
				node.addChild(content);
			}
			if (null != css.media)
				node.set("media", css.media);
			node.set("type", "text/css");
			conditionallyWrapNode(head, node, css.browser);
		}
	}
	
	function conditionallyWrapNode(head : Xml, node : Xml, browser : String)
	{
		if (!agentSensitiveOutput && null != browser && browser.indexOf("IE") >= 0)
		{
			head.addChild(Xml.createPCData("<!--[if " + browser + "]>"));
			head.addChild(node);
			head.addChild(Xml.createPCData("<![endif]-->"));
			
		} else {
			head.addChild(node);
		}
	}
	
	function getScripts() : Array<Script>
	{
		var scripts = _scripts.copy();
		var tscripts : Array<Dynamic> = viewData.get("scripts");
		if (null != tscripts)
			for (script in tscripts)
				scripts.push(scriptFromTemplate(script));
		var result : Array<Script> = [];
		for (input in scripts)
		{
			var found = false;
			for (output in result)
			{
				if (output.src == input.src)
				{
					if (null != input.charset && output.charset == null)
						output.charset = input.charset;
					if (input.defer == true && output.defer == null)
						output.defer = input.defer;
					found = true;
					break;
				}
			}
			if (!found)
				result.push(input);
		}
		if (agentSensitiveOutput)
			return result.filter(isAgentCompliant);
		else
			return result;
	}
	
	function isAgentCompliant(info : { browser : Null<String> } ) : Bool
	{
		if (null == info.browser)
			return true;
		var condition = extractCondition(info.browser);
		if (null == condition)
			throw new Error("invalid browser condition '{0}'", info.browser);
		if (condition.browser != _agent.browser.toLowerCase())
			return false;
		switch(condition.operator)
		{
			case "lt":
				return _agent.majorVersion < condition.majorVersion || (condition.majorVersion == _agent.majorVersion && null != condition.minorVersion && _agent.minorVersion < condition.minorVersion);
			case "gt":
				return _agent.majorVersion > condition.majorVersion || (condition.majorVersion == _agent.majorVersion && null != condition.minorVersion && _agent.minorVersion > condition.minorVersion);
			case "lte":
				return _agent.majorVersion <= condition.majorVersion || (condition.majorVersion == _agent.majorVersion && null != condition.minorVersion && _agent.minorVersion <= condition.minorVersion);
			case "gte":
				return _agent.majorVersion >= condition.majorVersion || (condition.majorVersion == _agent.majorVersion && null != condition.minorVersion && _agent.minorVersion >= condition.minorVersion);
			default:
				return true;
		}
	}
	
	static function extractCondition(s : String) : { browser : String, majorVersion : Null<Int>, minorVersion : Null<Int>, operator : Null<String> }
	{
		var parts = (~/\s+/g).split(StringTools.trim(s));
		if (parts.length == 0)
			return null;
			
		var browser = null;
		var majorVersion = null;
		var minorVersion = null;
		var operator = null;
		if (parts.length == 1)
		{
			browser = parts[0];
		} else if (parts.length != 3) {
			return null;
		} else {
			operator = parts[0];
			browser = parts[1];
			var re = ~/^(\d+)(?:\.(\d+))?$/;
			if (!re.match(parts[2]))
				return null;
			trace(parts[2] + " " + re.match(parts[2]));
			majorVersion = Std.parseInt(re.matched(1));
			trace(majorVersion);
			if (null != re.matched(2))
				minorVersion = Std.parseInt(re.matched(2));
		}
		
		if (browser == "IE")
			browser = "Explorer";
		
		return {
			browser : browser.toLowerCase(),
			majorVersion : majorVersion,
			minorVersion : minorVersion,
			operator : operator
		};
	}
	
	public function addScript(script : Script)
	{
		_scripts.push(script);
	}
	
	function getStyleSheets() : Array<StyleSheet>
	{
		var styleSheets = _styleSheets.copy();
		var tstyleSheets : Array<Dynamic> = viewData.get("styleSheets");
		if (null != tstyleSheets)
			for (styleSheet in tstyleSheets)
				styleSheets.push(styleSheetsFromTemplate(styleSheet));
		
		var result : Array<StyleSheet> = [];
		for (input in styleSheets)
		{
			var found = false;
			for (output in result)
			{
				if (output.href == input.href)
				{
					if (null != input.title && output.title == null)
						output.title = input.title;
					if (null != input.rel && output.rel == null)
						output.rel = input.rel;
					if (null != input.media)
					{
						if (null != output.media)
							output.media += "," + input.media;
						else
							output.media = input.media;
					}
					found = true;
					break;
				}
			}
			if (!found)
				result.push(input);
		}
		if (agentSensitiveOutput)
			return result.filter(isAgentCompliant);
		else
			return result;
	}
	
	public function addStyleSheet(styleSheet : StyleSheet)
	{
		_styleSheets.push(styleSheet);
	}
	
	function setTitle(v) return title = v
	function getTitle()
	{
		if(null != title)
			return title;
		else
			return viewData.get("title");
	}
	
	function setLanguage(v) return language = v
	function getLanguage()
	{
		if(null != language)
			return language;
		else if(viewData.exists("language"))
			return viewData.get("language");
		else
			return viewData.get("lang");
	}
	
	function setCharset(v) return charset = v
	function getCharset()
	{
		if(null != charset)
			return charset;
		else
			return viewData.get("charset");
	}
	
	static function styleSheetsFromTemplate(v : Dynamic)
	{
		return { 
			href    : Reflect.field(v, "href"),
			media   : Reflect.field(v, "media"),
			title   : Reflect.field(v, "title"),
			rel     : Reflect.field(v, "rel"),
			charset : Reflect.field(v, "charset"),
			style   : Reflect.field(v, "style"),
			browser : Reflect.field(v, "browser"),
		};
	}
	
	static function scriptFromTemplate(v : Dynamic)
	{
		return { 
			src     : Reflect.field(v, "src"),
			charset : Reflect.field(v, "charset"),
			defer   : Reflect.field(v, "defer"),
			script  : Reflect.field(v, "script"),
			browser : Reflect.field(v, "browser"),
		};
	}
	
	static function getParser(version) : String -> Xml
	{
		switch(version)
		{
			case Html401Strict, Html401Transitional, Html401Frameset, Html5:
				return Html.toXml;
			case XHtml10Transitional, XHtml10Frameset, XHtml10Strict, XHtml11:
				return Xml.parse;
		}
	}
	
	static function getContentType(version) : String
	{
		switch(version)
		{
			case Html401Strict, Html401Transitional, Html401Frameset, Html5:
				return "text/html";
			case XHtml10Transitional, XHtml10Frameset, XHtml10Strict, XHtml11:
				return "application/xhtml+xml";
		}
	}
	
	static function getFormatter(version) : XHtmlFormat
	{
		var format : XHtmlFormat;
		switch(version)
		{
			case Html401Strict, Html401Transitional, Html401Frameset:
				var f = new HtmlFormat();
				f.quotesRemoval = false;
				f.useCloseSelf = false;
				f.specialElementContentFormat = AsCommentedText;
				format = f;
			case Html5:
				var f = new HtmlFormat();
				f.quotesRemoval = true;
				f.useCloseSelf = true;
				f.specialElementContentFormat = AsPlainText;
				format = f;
			case XHtml10Transitional, XHtml10Frameset, XHtml10Strict, XHtml11:
				format = new XHtmlFormat();
		}
		format.autoformat = true;
		format.normalizeNewlines = true;
		return format;
	}
	
	static function getTemplate(version)
	{
		switch(version)
		{
			case Html401Strict:
				return getTemplateHtml4Strict();
			case Html401Transitional:
				return getTemplateHtml4Transitional();
			case Html401Frameset:
				return getTemplateHtml4Frameset();
			case Html5:
				return getTemplateHtml5();
			case XHtml10Transitional:
				return getTemplateXHtml10Transitional();
			case XHtml10Frameset:
				return getTemplateXHtml10Frameset();
			case XHtml10Strict:
				return getTemplateXHtml10Strict();
			case XHtml11:
				return getTemplateXHtml11();
		}   
	}
	
	static function getTemplateHtml4Strict()
	{
		return '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd"><html><head><title></title></head><body>{content}</body></html>';
	}
	
	static function getTemplateHtml4Transitional()
	{
		return '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd"><html><head><title></title></head><body>{content}</body></html>';
	}
	
	static function getTemplateHtml4Frameset()
	{
		return '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Frameset//EN" "http://www.w3.org/TR/html4/frameset.dtd"><html><head><title></title></head><frameset><noframes><body>{content}</body></noframes></frameset></html>';
	}
	
	static function getTemplateHtml5()
	{
		return '<!doctype html><html><head><title></title></head><body>{content}</body></html>';
	}
	
	static function getTemplateXHtml10Transitional()
	{
		return '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd"><html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head><body>{content}</body></html>';
	}
	
	static function getTemplateXHtml10Strict()
	{
		return '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"><html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head><body>{content}</body></html>';
	}
	
	static function getTemplateXHtml10Frameset()
	{
		return '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Frameset//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd"><html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head><frameset><noframes><body>{content}</body></noframes></frameset></html>';
	}
	
	static function getTemplateXHtml11()
	{
		return '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"><html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head><body>{content}</body></html>';
	}
}

enum HtmlVersion
{
	Html401Strict;
	Html401Transitional;
	Html401Frameset;
	Html5;
	XHtml10Transitional;
	XHtml10Strict;
	XHtml10Frameset;
	XHtml11;
}

typedef Script = {
	src     : Null<String>,
	charset : Null<String>,
	defer   : Null<Bool>,
	script  : Null<String>,
	browser : Null<String>
}

typedef StyleSheet = {
	href    : Null<String>,
	media   : Null<String>,
	title   : Null<String>,
	rel     : Null<String>,
	charset : Null<String>,
	style   : Null<String>,
	browser : Null<String>
}