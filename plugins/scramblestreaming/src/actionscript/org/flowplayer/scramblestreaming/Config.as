/*
 * This file is part of Flowplayer, http://flowplayer.org
 *
 * By: Anssi Piirainen, <support@flowplayer.org>
 * Copyright (c) 2008-2011 Flowplayer Oy *
 * Released under the MIT License:
 * http://www.opensource.org/licenses/mit-license.php
 */
 
package org.flowplayer.scramblestreaming {

	/**
	 * @author api
	 */
	
	import flash.system.Capabilities;
	
	public class Config {
		
		private var _queryString:String = "?start=${start}";
		private var _rangeRequests:Boolean;
		private var _policyURL:String;
		
		public function get queryString():String {
			return _queryString;
		}
		
		public function set queryString(queryString:String):void {
			_queryString = queryString;
		}
		
		public function get policyURL():String {
            return _policyURL;
        }
        
        public function set policyURL(policyURL:String):void {
            _policyURL = policyURL;
        }
		
		public function set rangeRequests(value:Boolean):void {
            _rangeRequests = value;
        }

        public function get rangeRequests():Boolean {
            return isFP10_1() && _rangeRequests;
        }

        //#409 version check was not working with Flash 11
        public function isFP10_1():Boolean {
            var va:Array = Capabilities.version.split(" ")[1].toString().split(",");
            if(int(va[0]) > 10) { return true; }
            if(int(va[0]) < 10) { return false; }
            if(int(va[1]) > 1) { return true; }
            if(int(va[1]) < 1) { return false; }
            return true;
        }
	}
}
