(() => {
  const root = document.documentElement;
  const sw = document.getElementById('themeSwitch');
  let stored;
  try { stored = localStorage.getItem('luti-theme'); } catch {}

  const systemDark = matchMedia('(prefers-color-scheme: dark)');
  const isDark = () => (root.dataset.theme === 'auto' ? systemDark.matches : root.dataset.theme === 'dark');

  function apply(theme) {
    root.dataset.theme = theme;
    sw.setAttribute('aria-checked', String(isDark()));
  }

  apply(stored === 'dark' || stored === 'light' ? stored : 'auto');
  systemDark.addEventListener('change', () => {
    if (root.dataset.theme === 'auto') sw.setAttribute('aria-checked', String(systemDark.matches));
  });

  sw.addEventListener('click', () => {
    const next = isDark() ? 'light' : 'dark';
    try { localStorage.setItem('luti-theme', next); } catch {}
    apply(next);
  });

  const bar = document.getElementById('appbar');
  const sentinel = document.createElement('div');
  sentinel.className = 'appbar__sentinel';
  document.body.prepend(sentinel);
  new IntersectionObserver(
    ([e]) => bar.classList.toggle('is-stuck', !e.isIntersecting),
    { rootMargin: '0px' }
  ).observe(sentinel);

  /* Menu keyboard navigation; closing restores focus to the trigger. */
  document.querySelectorAll('[data-menu]').forEach(menu => {
    const trigger = menu.querySelector('[aria-haspopup="menu"]');
    const surface = menu.querySelector('[role="menu"]');
    const items = [...surface.querySelectorAll('[role^="menuitem"]')];
    const focusAt = i => items[(i + items.length) % items.length].focus();

    function open(index) {
      surface.hidden = false;
      trigger.setAttribute('aria-expanded', 'true');
      focusAt(index ?? Math.max(0, items.findIndex(it => it.getAttribute('aria-checked') === 'true')));
    }
    function close(restore) {
      if (surface.hidden) return;
      surface.hidden = true;
      trigger.setAttribute('aria-expanded', 'false');
      if (restore) trigger.focus();
    }

    trigger.addEventListener('click', () => (surface.hidden ? open() : close(false)));
    trigger.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') { e.preventDefault(); open(0); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); open(items.length - 1); }
    });

    surface.addEventListener('keydown', e => {
      const at = items.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); focusAt(at + 1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); focusAt(at - 1); }
      else if (e.key === 'Home') { e.preventDefault(); focusAt(0); }
      else if (e.key === 'End') { e.preventDefault(); focusAt(items.length - 1); }
      else if (e.key === 'Escape') { e.preventDefault(); close(true); }
      else if (e.key === 'Tab') close(false);
    });
    items.forEach(it => it.addEventListener('click', () => close(true)));

    document.addEventListener('pointerdown', e => {
      if (!menu.contains(e.target)) close(false);
    });
  });

  const io = new IntersectionObserver(
    entries => entries.forEach(e => {
      if (!e.isIntersecting) return;
      e.target.classList.add('is-in');
      io.unobserve(e.target);
    }),
    { threshold: 0.12, rootMargin: '0px 0px -8% 0px' }
  );
  document.querySelectorAll('.reveal').forEach((el, i) => {
    el.style.transitionDelay = `${Math.min(i % 4, 3) * 60}ms`;
    io.observe(el);
  });
})();
