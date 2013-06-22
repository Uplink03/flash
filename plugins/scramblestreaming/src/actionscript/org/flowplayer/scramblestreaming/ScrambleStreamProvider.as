/*
 * This file is part of Flowplayer, http://flowplayer.org
 *
 * By: Anssi Piirainen, <support@flowplayer.org>
 * Copyright (c) 2008-2011 Flowplayer Oy
 * H.264 support by: Arjen Wagenaar, <h264@code-shop.com>
 * Copyright (c) 2009 CodeShop B.V.
 *
 * Released under the MIT License:
 * http://www.opensource.org/licenses/mit-license.php
 */

package org.flowplayer.scramblestreaming {
import flash.events.NetStatusEvent;
import flash.net.NetConnection;
import flash.net.NetStream;
import flash.system.Security;

import org.flowplayer.controller.NetStreamControllingStreamProvider;
import org.flowplayer.model.Clip;
import org.flowplayer.model.ClipEvent;
import org.flowplayer.model.ClipEventType;
import org.flowplayer.model.Plugin;
import org.flowplayer.model.PluginModel;
import org.flowplayer.util.PropertyBinder;
import org.flowplayer.view.Flowplayer;

/**
     * @author api
     */
    public class ScrambleStreamProvider extends NetStreamControllingStreamProvider implements Plugin {
        private var _bufferStart:Number;
        private var _config:Config;
        private var _fileWithKeyframeInfo:String;
        private var _serverSeekInProgress:Boolean;
        private var _startSeekDone:Boolean;
        private var _model:PluginModel;
        private var _seekDataStore:DefaultSeekDataStore;
        private var _currentClip:Clip;
        private var _player:Flowplayer;

        /**
         * Called by the player to set my config.
         */
        override public function onConfig(model:PluginModel):void
        {
            _model = model;
            _config = new PropertyBinder(new Config(), null).copyProperties(model.config) as Config;
        }

        /**
         * Called by the player to set the Flowplayer API.
         */
        override public function onLoad(player:Flowplayer):void
        {
            log.info("onLoad()");
            _model.dispatchOnLoad();
            _player = player;
        }

        override protected function getClipUrl(clip:Clip):String
        {
            return _config.rangeRequests ? clip.completeUrl : appendQueryString(clip.completeUrl, 0);
        }

        override protected function doLoad(event:ClipEvent, netStream:NetStream, clip:Clip):void
        {
            log.debug("doLoad()");
            _bufferStart = clip.currentTime;
            _startSeekDone = false;
            //#31 fix to dispatch start events properly when loading new items.
            _fileWithKeyframeInfo = null;
            if (! _seekDataStore || isNewFile(clip)) {
                _seekDataStore = new DefaultSeekDataStore();
            }

            _seekDataStore.reset();
            super.doLoad(event, netStream, clip);
        }

        private function isNewFile(clip:Clip):Boolean
        {
            return clip.url != _fileWithKeyframeInfo;
        }

        override protected function doSeek(event:ClipEvent, netStream:NetStream, seconds:Number):void
        {
            log.debug("doSeek()");
            var target:Number = clip.start + seconds;

            //if target is near the end do a server seek to get the correct seekpoint to end correctly.
            if (target >= clip.duration) {
                serverSeek(netStream, target);
                return;
            }

            if (isInBuffer(target)) {
                log.debug("seeking inside buffer, target " + target + " seconds");
                netStream.seek(_seekDataStore.inBufferSeekTarget(target));
             } else if (event) {
                //#630 when the event is null we're in silent seek during controlbar dragging, only seek when not silent.
                silentSeek = false;
                serverSeek(netStream, target);
            }
        }

        override protected function doStop(event:ClipEvent, netStream:NetStream, closeStreamAndConnection:Boolean = false):void
        {
            //reset the current clip
            _currentClip = null;
            log.debug("Clearing clip and stopping ");
            super.doStop(event, netStream, closeStreamAndConnection);
        }

        override protected function doSwitchStream(event:ClipEvent, netStream:NetStream, clip:Clip, netStreamPlayOptions:Object = null):void
        {
            log.debug("doSwitchStream()");
            clip.currentTime = time;
            _bufferStart = clip.currentTime;
            _currentClip = clip;

            log.debug("Switching stream with current time: " + clip.currentTime);

            //#385 regression issue caused by #365, added old switching code back in, and tested seeking and switching work correctly.
            clip.unbind(onMetaData);
            clip.onMetaData(switchOnMetaData);

            //#404 refactoring switchStream to suit changes with http streams and the use of the play2 method for resetting the stream.
            super.doSwitchStream(event, netStream, clip, netStreamPlayOptions);
        }

        private function switchOnMetaData(event:ClipEvent):void
        {
            log.debug("switchOnMetaData(), netStream " + netStream);
            clip.onMetaData(onMetaData);
            clip.unbind(switchOnMetaData);
            _startSeekDone = true;
            createSeekDataStore(Clip(event.target));
            serverSeek(netStream, Clip(event.target).currentTime, true);
        }

        override public function get bufferStart():Number
        {
            if (! clip) return 0;
            return _bufferStart - clip.start;
        }

        override public function get bufferEnd():Number
        {
            if (! netStream) return 0;
            if (! clip) return 0;
            return bufferStart + netStream.bytesLoaded / netStream.bytesTotal * (clip.duration - bufferStart);
        }

        override protected function getCurrentPlayheadTime(netStream:NetStream):Number
        {
            if (! clip) return 0;
            var value:Number = _seekDataStore.currentPlayheadTime(netStream.time, clip.start);

            if (clip.duration != clip.durationFromMetadata && Math.abs(clip.duration - value) <= 1) {
                // duration configured and we are reaching the end. Round the value so that end is reached at the correct configured end point.
                return Math.round(value);
            }
            return value < 0 ? 0 : value;
        }

        override public function get allowRandomSeek():Boolean
        {
            if (! _seekDataStore) return false;
            return _seekDataStore.allowRandomSeek();
        }

        private function isInBuffer(seconds:Number):Boolean
        {
            if (!_seekDataStore.dataAvailable) {
                log.debug("No keyframe data available, can only seek inside the buffer");
                return true;
            }

            if (_config.rangeRequests) return false;

            return bufferStart <= seconds - clip.start && seconds - clip.start <= bufferEnd;
        }

        private function serverSeek(netStream:NetStream, seconds:Number, setBufferStart:Boolean = true):void
        {
            log.debug("serverSeek()");
            if (setBufferStart) {
                _bufferStart = seconds;
            }

            if (_config.rangeRequests) {
                //#409 preventing seeking during silent seeking as is unstable with byte range seeking.
                if (silentSeek) return;
                log.debug("Making range request to server, usin URL " + clip.completeUrl);
                netStream.play(clip.completeUrl, seconds, _seekDataStore);
                return;
            }

            // issue #315
            //this resets on replay before time is updated
            if (seconds == 0) {
                _seekDataStore.reset();
            }

            var requestUrl:String = appendQueryString(clip.completeUrl, seconds);
            log.debug("doing server seek, url " + requestUrl);
            _serverSeekInProgress = true;
            netStream.play(requestUrl);

        }

        private function getByteRange(start:Number):Number
        {
            return  _seekDataStore.getQueryStringStartValue(start);
        }

        private function appendQueryString(url:String, start:Number):String
        {
            log.debug("appendQueryString(), start == " + start);
            // http://flowplayer.org/forum/7/48461
            if (start == 0) return url;

            //#565 append the url params to the generated start param
            //#568 fix parameter undefined issue
            var urlParts:Array = url.split("?");
            var query:String = urlParts[0] +  _config.queryString.replace("${start}", _seekDataStore.getQueryStringStartValue(start)) + (urlParts[1] !== undefined ? ("&" + urlParts[1]) : "");

            log.debug("query string is " + query);
            return query;
        }

        override protected function onMetaData(event:ClipEvent):void
        {
            if (_startSeekDone) {
                return;
            }

            log.info("received metaData for clip" + Clip(event.target));
            log.debug("clip file is " + clip.url);

            if (isNewFile(event.target as Clip)) {
                log.info("new file, creating new keyframe store");
                createSeekDataStore(Clip(event.target));
                clip.dispatch(ClipEventType.START, pauseAfterStart);

                // at this point we seek to the start position if it's greater than zero
                log.debug("seeking to start, pausing after start: " + pauseAfterStart);
                if (clip.start > 0) {
                    serverSeek(netStream, clip.start, true);

                } else if (pauseAfterStart) {
                    log.debug("started: pausing to pos 0 in netStream");
                    //#486 implement pauseToFrame to unmute audio when autoBuffering.
                    pauseToFrame();
                }
            }
        }


        override protected function pauseToFrame():void
        {
            log.debug("seeking to frame zero");
            //#363 pause stream here after metadata or else no metadata is sent for rtmp clips
            pause(new ClipEvent(ClipEventType.PAUSE));

            //#363 silent seek and force to seek to a frame or else video will not display
            silentSeek = true;

            //#602 don't seek to frame when start is set.
            if (!clip.start) netStream.seek(0);
            _player.muted = false;
            pauseAfterStart = false;
        }

        private function createSeekDataStore(clip:Clip):void
        {
            _seekDataStore = DefaultSeekDataStore.create(clip, clip.metaData);

            // # 75, events should be dispatched only once
            _fileWithKeyframeInfo = clip.url;
        }

        override protected function canDispatchBegin():Boolean
        {
            // before start seek we dispatch the initial onBegin
            if (! _startSeekDone) return true;

            if (_serverSeekInProgress) return false;
            return true;
        }

        override protected function onNetStatus(event:NetStatusEvent):void
        {
            log.info("onNetStatus: " + event.info.code);
            // #61, must wait buffer full instead of Play.Start for videos without metadatas.
            if (event.info.code == "NetStream.Buffer.Full") {

                // at this stage the server seek is in target, and we can dispatch the seek event
                //#630 regression move seek event dispatching to buffer full or else the time hasn't been updated yet.
                if (_serverSeekInProgress) {
                    _startSeekDone = true;
                    _serverSeekInProgress = false;

                    //#568 when paused and seeking, silentseek is true therefore check also for paused to dispatch seek.
                    if (paused || !silentSeek) {
                        clip.dispatch(ClipEventType.SEEK, seekTarget);
                    }

                    if (this.switching) {
                         //#385 dispatch switch complete event
                        this.dispatchEvent(new ClipEvent(ClipEventType.SWITCH_COMPLETE));
                        this.switching = false;
                    } else if (paused) {
                        //#568 when seeking when paused pause the stream here again.
                        netStream.pause();
                    }
                }

                log.debug("started, will pause after start: " + pauseAfterStart);
                // we need to pause here because the stream was started when server-seeking to start pos
                if (pauseAfterStart) {
                    if (_startSeekDone) {
                        //#363 pause after the server seek here
                        switching = false;
                        //#486 implement pauseToFrame to unmute audio when autoBuffering.
                        pauseToFrame();
                    }
                }
            } else if  (event.info.code == "NetStream.Seek.InvalidTime") {
                //#385 when scrubbing to the edge of the buffer seeking sometimes failed, need to reset the seek time to continue playback.
                log.debug("Buffer seek failed, setting seek time to " + event.info.details);
                netStream.seek(event.info.details); //to the closest valid seek time by looking in the info object
			    netStream.resume();
            } else if (event.info.code == "NetStream.Play.Stop") {
                //#403 when seeking to outside the allowed keyframes, stop is called, require to trigger buffer full to complete correctly.
                if (_serverSeekInProgress) {
                    _startSeekDone = true;
                    _serverSeekInProgress = false;
                    clip.dispatch(ClipEventType.BUFFER_FULL);
                }
            }

        }

        public function getDefaultConfig():Object
        {
            return null;
        }

        override public function get type():String
        {
            return "pseudo";
        }

        override protected function createNetStream(connection:NetConnection):NetStream
        {
            CONFIG::enableByteRange {
                import org.flowplayer.scramblestreaming.net.ByteRangeNetStream;

                if (_config.rangeRequests) {
                    log.debug("Using ByteRangeNetStream");

                    Security.allowInsecureDomain("*");
                    Security.allowDomain("*");
                    if (_config.policyURL) Security.loadPolicyFile("xmlsocket://" + _config.policyURL);

                    return new ByteRangeNetStream(connection);
                }
            }
            return null;
        }
    }
}