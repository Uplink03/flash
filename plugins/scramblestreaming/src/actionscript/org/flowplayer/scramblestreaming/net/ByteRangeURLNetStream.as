package org.flowplayer.scramblestreaming.net
{
    import flash.events.Event;
    import flash.events.HTTPStatusEvent;
    import flash.events.IOErrorEvent;
    import flash.events.NetStatusEvent;
    import flash.events.ProgressEvent;
    import flash.events.SecurityErrorEvent;

    import flash.net.NetConnection;
    import flash.net.NetStream;
    import flash.net.URLStream;
    import flash.net.NetStreamAppendBytesAction;
    //import flash.system.Security;
    import flash.utils.ByteArray;
    import flash.utils.setTimeout;

    import flash.net.URLRequest;

    import org.flowplayer.scramblestreaming.DefaultSeekDataStore;
    import org.flowplayer.util.Log;

    public class ByteRangeURLNetStream extends NetStream
	{
		private var _urlStream:URLStream;
		private var _bytesTotal:uint = 0;
		private var _bytesLoaded:uint = 0;
		private var _seekTime:uint = 0;
		private var _currentURL:String;
		private var _seekDataStore:DefaultSeekDataStore;
		protected var log:Log = new Log(this);
		private var _ended:Boolean;

		private var _buffer:ByteArray = new ByteArray();

		public function ByteRangeURLNetStream(connection:NetConnection, peerID:String="connectToFMS")
		{
			super(connection, peerID);
		}

		private function onOpen(event:Event):void
		{
			log.debug("Stream open");

			_bytesLoaded = 0;
			_bytesTotal = 0;
			
			appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
			
			dispatchEvent(new NetStatusEvent(
				NetStatusEvent.NET_STATUS,
				false,
				false,
				{code: "NetStream.Play.Start", level: "status"}
			));
		}
		
		private function onComplete(event:Event):void
		{
			log.debug("Stream complete");

			_seekTime = _seekTime + 1;
			_ended = true;
			this.appendBytesAction(NetStreamAppendBytesAction.END_SEQUENCE);

			dispatchEvent(new NetStatusEvent(
				NetStatusEvent.NET_STATUS,
				false,
				false,
				{code: "NetStream.Play.Stop", level: "status"}
			));
		}

		private function onStatus(event:HTTPStatusEvent):void
		{
			log.debug("HTTP Status: " + event.status);
			switch (event.status)
			{
				case 404: 
					dispatchEvent(new NetStatusEvent(
						NetStatusEvent.NET_STATUS,
						false,
						false,
						{code:"NetStream.Play.StreamNotFound", level:"error"}
					)); 
					break;
				case 200:
				default:
					break;
			}
		}

		private function onSecurityError(event:SecurityErrorEvent):void
		{
			log.debug("Security error has occured: " + event.text);
			dispatchEvent(new NetStatusEvent(
				NetStatusEvent.NET_STATUS,
				false,
				false,
				{code:"NetStream.Play.Failed", level:"error", message: event.text}
			)); 
		}

		private function onIOError(event:IOErrorEvent):void
		{
			log.debug("IO error has occured: " + event.text);
			dispatchEvent(new NetStatusEvent(
				NetStatusEvent.NET_STATUS,
				false,
				false,
				{code:"NetStream.Play.Failed", level:"error", message: event.text}
			)); 
		}

		private function onProgress(event:ProgressEvent):void
		{
			if (!_bytesTotal) _bytesTotal = event.bytesTotal;

			if (_urlStream.bytesAvailable == 0)
				return;

			/*
			log.debug("Progress:" +
				" loaded: " + event.bytesLoaded +
				" total: " + event.bytesTotal +
				" available: " + _urlStream.bytesAvailable
			);
			*/
			
			var bytes:ByteArray = new ByteArray();
			_urlStream.readBytes(bytes);

			var encbytes:ByteArray = new ByteArray();
			for (var i:uint = 0; i < bytes.length; i++)
				encbytes[i] = ((~bytes[i]) & 0xff);

			_buffer.writeBytes(encbytes);
			appendBytes(encbytes);
			_bytesLoaded += encbytes.length;
		}

		override public function get bytesTotal():uint {
			return _bytesTotal;
		}
		
		override public function get bytesLoaded():uint {
			return _bytesLoaded;
		}
		
		override public function play(...parameters):void {
			log.debug("ByteRangeURLStream play: " + parameters[0] + " " + parameters[1] + " " + parameters[2]);
			
			super.play(null);

			if (Number(parameters[1]) && DefaultSeekDataStore(parameters[2])) {
				_seekTime = Number(parameters[1]);
				_seekDataStore = DefaultSeekDataStore(parameters[2]);

				super.seek(0);
				this.appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
				
				var bytePos:uint = getByteRange(_seekTime);
				log.debug("_seekTime: " + _seekTime + "; bytePos: " + bytePos);

				var bytes:ByteArray = new ByteArray();
				_buffer.position = bytePos;
				_buffer.readBytes(bytes);
				// _buffer.position is now at the end of _buffer?
				appendBytes(bytes);

				dispatchEvent(new NetStatusEvent(NetStatusEvent.NET_STATUS,false,false, {code:"NetStream.Play.Seek", level:"status"}));
			} else {

				//reset seek, bytes loaded and send bytes reset actions
				_seekTime = 0;
				_bytesLoaded = 0;
				//this.appendBytesAction(NetStreamAppendBytesAction.END_SEQUENCE);
				this.appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
				dispatchEvent(new NetStatusEvent(NetStatusEvent.NET_STATUS,false,false, {code:"NetStream.Play.Start", level:"status"}));

				if (!_urlStream)
				{
					_urlStream = new URLStream();

					_urlStream.addEventListener(Event.OPEN, onOpen);
					_urlStream.addEventListener(ProgressEvent.PROGRESS, onProgress);
					_urlStream.addEventListener(Event.COMPLETE, onComplete);

					//_urlStream.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, onResponseStatus); // AIR only
					_urlStream.addEventListener(HTTPStatusEvent.HTTP_STATUS, onStatus);

					_urlStream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);
					_urlStream.addEventListener(IOErrorEvent.IO_ERROR, onIOError);
				}
				else
				{
					if (_urlStream.connected) _urlStream.close();
				}

				_currentURL = parameters[0];
				var urlRequest:URLRequest = new URLRequest(_currentURL);
				_urlStream.load(urlRequest);
			}
		}
		
		private function getByteRange(start:Number):Number {
			return  _seekDataStore.getQueryStringStartValue(start);
		}
		
		override public function seek(seconds:Number):void {
			play(_currentURL, seconds, _seekDataStore);
		}
		
		override public function get time():Number {
			return _seekTime + super.time;	
		}
		
	}
}
