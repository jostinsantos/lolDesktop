/**
 * Plantilla Nuvio — index.js
 * Funciones: getHome, getDiscover, search, getMeta, getStreams
 * Config del usuario: globalThis.__nuvioConfig.current
 */

function sampleItems() {
  return [
    {
      id: 'demo_1',
      title: 'Big Buck Bunny',
      type: 'movie',
      year: '2008',
      rating: 7.5,
      poster: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/images/BigBuckBunny.jpg',
      overview: 'Un conejo grande y un par de roedores.',
    },
    {
      id: 'demo_2',
      title: 'Elephant Dream',
      type: 'movie',
      year: '2006',
      rating: 7.0,
      poster: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/images/ElephantsDream.jpg',
      overview: 'El primer cortometraje open movie de Blender.',
    },
    {
      id: 'demo_3',
      title: 'Sintel',
      type: 'movie',
      year: '2010',
      rating: 7.8,
      poster: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/images/Sintel.jpg',
      overview: 'Una joven busca a un dragón bebé.',
    },
  ];
}

function getHome() {
  var items = sampleItems();
  return {
    rows: [
      { id: 'top', title: 'TOP PICKS', items: items },
      { id: 'more', title: 'Más contenido', items: items.slice().reverse() },
    ],
  };
}

function getDiscover(opts) {
  return { items: sampleItems() };
}

function search(query) {
  var q = (query || '').toLowerCase();
  return {
    items: sampleItems().filter(function (m) {
      return m.title.toLowerCase().indexOf(q) >= 0;
    }),
  };
}

function getMeta(id) {
  var found = sampleItems().find(function (m) { return m.id === id; });
  return found || sampleItems()[0];
}

function getStreams(id) {
  var cfg = (globalThis.__nuvioConfig && globalThis.__nuvioConfig.current) || {};
  // cfg.api_key disponible si el usuario la configuró
  return {
    streams: [
      {
        name: 'MP4 Demo',
        url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
        quality: '1080p',
        language: 'en',
      },
      {
        name: 'HLS Demo',
        url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
        quality: 'auto',
        language: 'en',
      },
    ],
  };
}

if (typeof module !== 'undefined') {
  module.exports = {
    getHome: getHome,
    getDiscover: getDiscover,
    search: search,
    getMeta: getMeta,
    getStreams: getStreams,
  };
}
