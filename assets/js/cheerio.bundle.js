/* Minimal cheerio-like stub for flutter_js when full bundle is unavailable.
   Real scrapers that need cheerio should ship with a proper browser bundle. */
(function(root){
  function load(html){
    var doc = { html: String(html||'') };
    function $(sel){
      return {
        text: function(){
          var m = doc.html.match(new RegExp('<'+String(sel).replace('.','')+'[^>]*>([^<]*)','i'));
          if (sel && String(sel).indexOf('.')>=0) {
            var cls = String(sel).split('.')[1];
            var re = new RegExp('class=["\'][^"\']*'+cls+'[^"\']*["\'][^>]*>([^<]*)','i');
            var mm = doc.html.match(re);
            return mm ? mm[1] : '';
          }
          return m ? m[1] : '';
        },
        html: function(){ return doc.html; },
        find: function(){ return $(sel); },
        attr: function(){ return null; },
        each: function(fn){ return this; },
        length: 0
      };
    }
    $.load = load;
    return $;
  }
  var api = { load: load };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.cheerio = api;
  root.__libExport = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
