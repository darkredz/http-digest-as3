﻿/*
 * Copyright (c) 2012, Paul McMonagle
 * See LICENSE.md for details.
 */
package ca.pmcmonagle.net {
	
	import flash.net.URLRequest;
	import flash.net.URLRequestHeader;
	import flash.net.URLRequestMethod;
	import flash.net.URLLoader;
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.HTTPStatusEvent;
	import flash.events.IOErrorEvent;
	
	/** 
	 * HTTP Digest relies on the MD5 cryptography
	 * class found in the as3corelib package.
	 * The as3corelib package can be found here:
	 * https://github.com/mikechambers/as3corelib
	 */
	import com.adobe.crypto.MD5;
	
	/**
	 * This class is used to manually handle HTTPDigest
	 * authentication. WARNING: this class will overwrite
	 * the request headers of the URLRequest that is passed
	 * into it. This is necessary for proper authentication.
	 */
	public class HTTPDigest extends EventDispatcher {
		
		public var data:String;
		private var user:String;
		private var pass:String;
		private var urlRequest:URLRequest;
		
		/** 
		 * @constructor
		 * @param {String} user  Pass in a user to authenticate as.
		 * @param {String} pass  Pass in a password to authenticate with.
		 */
		public function HTTPDigest(user:String, pass:String):void {
			this.user = user;
			this.pass = pass;
		}
		
		/** 
		 * Initiate the request process.
		 * Pass in a callback function to receive the data upon completion.
		 */
		public function load(urlRequest:URLRequest):void {
			this.urlRequest = urlRequest;
			this.requestAuthHeaders();
		}
		
		/**
		 * We begin with an unauthorized URLRequest.
		 * The correct response should be 401 - unauthorized
		 * accompanied by nonce values in the HTTP Header
		 */
		private function requestAuthHeaders():void {
			var req:URLRequest = this.urlRequest;
			req.authenticate = false;
			req.requestHeaders = [];
			
			var loader:URLLoader = new URLLoader();
			loader.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusHandler);
			loader.addEventListener(IOErrorEvent.IO_ERROR, errorHandler);
			loader.load(req);
			
			var scope = this;
			function statusHandler(e:HTTPStatusEvent):void {
				e.target.removeEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusHandler);
				e.target.removeEventListener(IOErrorEvent.IO_ERROR, errorHandler);
				
				if(e.status === 401) {
					makeAuthorizedRequest(e.responseHeaders);
				} else if(e.status.toString().match(/2(0|2)[0-8]/)) {
					e.target.addEventListener(Event.COMPLETE, responseHandler);
				} else {
					var error:IOErrorEvent = new IOErrorEvent(IOErrorEvent.IO_ERROR, false, false, "HTTPDigest - Server responded to authorization request with a status of "+e.status+"; expected 200, 201 or 401.", 0);
					scope.data = "";
					scope.dispatchEvent(error);
				}
			}
			function responseHandler(e:Event):void {
				e.target.removeEventListener(Event.COMPLETE, responseHandler);
				
				scope.data = e.target.data;
				scope.dispatchEvent(e);
				trace("HTTPDigest - Request succeded on first attempt; no authentication was necessary.");
			}
			function errorHandler(e:IOErrorEvent):void {
				e.target.removeEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusHandler);
				e.target.removeEventListener(IOErrorEvent.IO_ERROR, errorHandler);
				
				scope.data = e.target.data;
				scope.dispatchEvent(e);
			}
		}
		
		private function makeAuthorizedRequest(responseHeaders:Array):void {
			// Convert the array to an object for easy access to each member.
			var responseObject:Object = this.parseDigestValues(responseHeaders);
			
			// Choose QOP based on available options; auth-int is always preferred.
			var qop:String = ("qop" in responseObject) ? (responseObject.qop === "auth,auth-int" || responseObject.qop === "auth-int,auth") ? "auth-int" : responseObject.qop : "default";
			
			// Nonce Count - incremented by the client.
			var nc:String = "00000001";
			
			// Generate a client nonce value for auth-int protection.
			var cnonce:String = MD5.hash(Math.random().toString());
			
			// Remove the realm to get just the uri
			var uri:String = this.urlRequest.url.replace("http://"+responseObject.realm, "");
			
			// Modify the headers to support Digest Authentication
			this.urlRequest.authenticate = false;
			this.urlRequest.requestHeaders = [
				new URLRequestHeader("Content-Type", this.urlRequest.contentType),
				new URLRequestHeader("Authorization",
					"Digest "+
					"username=\"" + this.user             /* Username we are using to gain access. */ + "\", "+
					"realm=\""    + responseObject.realm  /* Same value we got from the server.    */ + "\", "+
					"nonce=\""    + responseObject.nonce  /* Same value we got from the server.    */ + "\", "+
					"uri=\""      + uri                   /* URI that we are attempting to access. */ + "\", "+ // TODO URI?! vs URL?!
					"qop="        + qop                   /* QOP as decided upon above.            */ + ", "+
					"nc="         + nc                    /* Nonce Count as decided upon above.    */ + ", "+
					"cnonce=\""   + cnonce                /* Client generated nonce value.         */ + "\", "+
					"response=\"" + this.generateResponse(responseObject, qop, nc, cnonce, uri)  /* Generate a hashed response based on HTTP Digest specifications. */ + "\", "+
					"opaque=\""   + responseObject.opaque /* Same value we got from the server.    */ + "\""
				)
			];
			
			var loader:URLLoader = new URLLoader();
			loader.addEventListener(Event.COMPLETE, responseHandler);
			loader.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusHandler);
			loader.addEventListener(IOErrorEvent.IO_ERROR, errorHandler);
			loader.load(this.urlRequest);
			
			var scope = this;
			function responseHandler(e:Event):void {
				e.target.removeEventListener(Event.COMPLETE, responseHandler);
				e.target.removeEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusHandler);
				e.target.removeEventListener(IOErrorEvent.IO_ERROR, errorHandler);
				
				scope.data = e.target.data ? e.target.data : '{"Error":"401"}';
				scope.dispatchEvent(e);
			}
			function statusHandler(e:HTTPStatusEvent):void {
				if(e.status === 200 || e.status === 201) {
					trace("HTTPDigest - Authentication Succeeded: "+e.status);
				}
				if(e.status === 401) {
					trace("HTTPDigest - Authentication Failed: 401");
				}
			}
			function errorHandler(e:IOErrorEvent):void {
				e.target.removeEventListener(Event.COMPLETE, responseHandler);
				e.target.removeEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusHandler);
				e.target.removeEventListener(IOErrorEvent.IO_ERROR, errorHandler);
				
				scope.data = e.target.data;
				scope.dispatchEvent(e);
			}
		}
		
		/** 
		 * Convert an array of response headers to an object with key:value pairs.
		 * @return Object
		 */
		private function parseDigestValues(responseHeaders:Array):Object {
			var obj:Object = {};
			var digestString:String;
			var digestArray:Array;
			var i:uint;
			
			for(i=0; i<responseHeaders.length; i++) {
				if(responseHeaders[i].name.toLowerCase() === "www-authenticate") {
					digestString = responseHeaders[i].value;
				}
			}
			
			// First, remove "Digest " from the begining of the string.
			digestArray = digestString.split(" ");
			digestArray.shift();
			
			// Join the remaining elements back together.
			digestString = digestArray.join(" ");
			
			// Next, split on ", " to get strings of key="value" pairs.
			digestArray = digestString.split(/,\s+/);
			// Finally, we break each item in the array on "="
			for(i=0; i<digestArray.length; i++) {
				var item:Array = digestArray[i].split("=");
				item[1] = item[1].replace(/"/g, '');
				obj[item[0]] = item[1];
			}
			
			return obj;
		}
		
		/** 
		 * Generate a response based on qop and the responseObject.
		 * @return {String}  Returns an MD5 hash response.
		 */
		private function generateResponse(responseObject:Object, qop:String, nc:String, cnonce:String, uri:String):String {
			var hash:String;
			var HA1:String;
			var HA2:String;
			
			HA1 = MD5.hash(this.user +":"+ responseObject.realm +":"+ this.pass);
			
			// HA2
			switch(qop) {
				case "auth-int":
					HA2 = MD5.hash(this.urlRequest.method +":"+ uri +":"+ MD5.hash(this.urlRequest.data.toString()));
					break;
				case "auth":
				default:
					HA2 = MD5.hash(this.urlRequest.method +":"+ uri);
					break;
			}
			
			// Response Hash
			switch(qop) {
				case "auth":
				case "auth-int":
					hash = MD5.hash(HA1 +":"+ responseObject.nonce +":"+ nc +":"+ cnonce +":"+ qop +":"+ HA2);
					break;
				default:
					hash = MD5.hash(HA1 +":"+ responseObject.nonce +":"+ HA2);
					break;
			}
			
			return hash;
		}
		
	}
}
