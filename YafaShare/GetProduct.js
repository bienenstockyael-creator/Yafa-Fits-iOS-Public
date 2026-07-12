// Runs INSIDE the shared web page in Safari (real browser, real session — past
// any bot-wall). Extracts product fields and hands them to the share extension
// via the completion function. The extension sends these straight to
// `share-save`, so the server never has to fetch the (bot-blocked) page.

var ExtensionPreprocessingJS = function () {};

ExtensionPreprocessingJS.prototype = {
  run: function (args) {
    // BELT-AND-SUSPENDERS: in Safari's JS-preprocessing mode the page
    // URL reaches the extension ONLY through this script's completion
    // call — if anything below throws uncaught, the share sheet gets
    // nothing and shows "No link to save". Whatever happens, complete
    // with at least the URL; the server-side scrape covers the rest.
    try {
      this.runUnsafe(args);
    } catch (e) {
      try { args.completionFunction({ url: document.URL }); } catch (e2) {}
    }
  },

  runUnsafe: function (args) {
    function meta(prop) {
      var el =
        document.querySelector('meta[property="' + prop + '"]') ||
        document.querySelector('meta[name="' + prop + '"]');
      return el ? el.getAttribute("content") : null;
    }

    var name = null, image = null, price = null, brand = null;

    // Prefer JSON-LD Product data (richest + most reliable on retail sites).
    try {
      var blocks = document.querySelectorAll('script[type="application/ld+json"]');
      for (var i = 0; i < blocks.length && !image; i++) {
        var data;
        try { data = JSON.parse(blocks[i].textContent); } catch (e) { continue; }
        var nodes = Array.isArray(data) ? data : (data["@graph"] || [data]);
        for (var j = 0; j < nodes.length; j++) {
          var n = nodes[j];
          if (!n) continue;
          var t = n["@type"];
          var isProduct = t === "Product" || (Array.isArray(t) && t.indexOf("Product") >= 0);
          if (!isProduct) continue;
          if (!name && n.name) name = n.name;
          if (!image) {
            var img = Array.isArray(n.image) ? n.image[0] : n.image;
            image = img && img.url ? img.url : img;
          }
          if (!brand) brand = typeof n.brand === "string" ? n.brand : (n.brand && n.brand.name);
          var off = Array.isArray(n.offers) ? n.offers[0] : n.offers;
          if (off && off.price != null) {
            price = (off.priceCurrency ? off.priceCurrency + " " : "") + off.price;
          }
        }
      }
    } catch (e) {}

    if (!name) name = meta("og:title") || document.title;
    if (!image) image = meta("og:image:secure_url") || meta("og:image") || meta("twitter:image");
    if (!price) price = meta("product:price:amount") || meta("og:price:amount");
    if (!brand) brand = meta("og:site_name");

    // Coerce to strings — JSON-LD in the wild puts objects where
    // strings belong, and a non-string field poisons the plist the
    // extension decodes (fields silently read as nil at best).
    function str(v) { return typeof v === "string" && v ? v : null; }

    function done(imageData) {
      args.completionFunction({
        url: document.URL,
        name: str(name),
        image: str(image),
        imageData: str(imageData),
        price: str(price) || (typeof price === "number" ? String(price) : null),
        brand: str(brand),
      });
    }

    // The browser can reach the (often bot-walled) retailer image even when
    // our server can't, so grab the bytes here, downscale, and hand them over
    // as a compact base64 JPEG. FAL then never has to fetch the protected URL.
    if (!image) { done(null); return; }

    var settled = false;
    function finishOnce(data) { if (!settled) { settled = true; done(data); } }
    setTimeout(function () { finishOnce(null); }, 4500); // never hang the sheet

    try {
      var img = new Image();
      img.crossOrigin = "anonymous";
      img.onload = function () {
        try {
          var max = 1100;
          var w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
          var scale = Math.min(1, max / Math.max(w, h));
          var cw = Math.max(1, Math.round(w * scale)), ch = Math.max(1, Math.round(h * scale));
          var canvas = document.createElement("canvas");
          canvas.width = cw; canvas.height = ch;
          canvas.getContext("2d").drawImage(img, 0, 0, cw, ch);
          finishOnce(canvas.toDataURL("image/jpeg", 0.86));
        } catch (e) { finishOnce(null); } // tainted canvas / cross-origin
      };
      img.onerror = function () { finishOnce(null); };
      img.src = image;
    } catch (e) { finishOnce(null); }
  },

  finalize: function (args) {},
};

var ExtensionPreprocessingJS = new ExtensionPreprocessingJS();
