function setLang(lang, button) {
  document.body.classList.toggle('zh-mode', lang === 'zh');
  document.documentElement.lang = lang === 'zh' ? 'zh' : 'en';

  var titleZh = document.body.getAttribute('data-title-zh');
  var titleEn = document.body.getAttribute('data-title-en');
  if (titleZh && titleEn) {
    document.title = lang === 'zh' ? titleZh : titleEn;
  }

  document.querySelectorAll('.lang-switch button').forEach(function(btn) {
    btn.classList.toggle('active', btn === button);
  });

  localStorage.setItem('pacgate-lang', lang);
  document.dispatchEvent(new CustomEvent('pacgate-langchange', {
    detail: { lang: lang }
  }));
}

(function initLang() {
  var requested = null;
  try {
    requested = new URLSearchParams(window.location.search).get('lang');
  } catch (error) {
    requested = null;
  }

  var saved = requested === 'zh' || requested === 'en'
    ? requested
    : (localStorage.getItem('pacgate-lang') || 'en');
  var button = document.querySelector('.lang-switch button[data-lang="' + saved + '"]');
  if (button) {
    setLang(saved, button);
  }
})();