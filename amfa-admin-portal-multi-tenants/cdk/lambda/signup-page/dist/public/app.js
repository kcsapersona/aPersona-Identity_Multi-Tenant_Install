// Signup page script. Talks only to this site's own /api/* (no keys in the browser).
(() => {
  const $ = (sel) => document.querySelector(sel);
  const steps = ['step-email', 'step-code', 'step-profile', 'step-done'];
  const siteKey = document.body.dataset.turnstileSitekey;
  let email = '';
  let turnstileToken = '';

  function show(id) {
    steps.forEach((s) => { $('#' + s).hidden = s !== id; });
    const n = steps.indexOf(id);
    document.querySelectorAll('.steps span').forEach((el, i) => el.classList.toggle('on', i <= n));
    const first = $('#' + id).querySelector('input');
    if (first) first.focus();
  }

  function msg(form, text, kind = 'err') {
    const el = form.querySelector('.msg');
    el.textContent = text || '';
    el.className = 'msg ' + (text ? kind : '');
  }

  async function api(path, body) {
    let res;
    try {
      res = await fetch('/api/' + path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify(body || {}),
      });
    } catch {
      return { ok: false, data: { message: 'Network problem. Check your connection and try again.' } };
    }
    const data = await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, data };
  }

  async function busy(form, fn) {
    const btn = form.querySelector('button[type=submit]');
    if (btn) btn.disabled = true;
    try { await fn(); } finally { if (btn) btn.disabled = false; }
  }

  show('step-email');

  // Optional Cloudflare Turnstile
  if (siteKey) {
    window.onTurnstileLoad = () => window.turnstile.render('#turnstile', {
      sitekey: siteKey,
      callback: (t) => { turnstileToken = t; },
      'expired-callback': () => { turnstileToken = ''; },
    });
    const s = document.createElement('script');
    s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onTurnstileLoad&render=explicit';
    s.async = true;
    document.head.appendChild(s);
  }

  async function sendCode(form) {
    const r = await api('start', { email, turnstileToken });
    if (siteKey && window.turnstile) { window.turnstile.reset('#turnstile'); turnstileToken = ''; }
    return r;
  }

  // Step 1
  $('#step-email').addEventListener('submit', (e) => {
    e.preventDefault();
    const form = e.currentTarget;
    email = $('#email').value.trim().toLowerCase();
    msg(form, '');
    busy(form, async () => {
      const r = await sendCode(form);
      if (!r.ok) return msg(form, r.data.message || 'Could not send the code.');
      $('#sent-to').textContent = email;
      $('#code').value = '';
      msg($('#step-code'), '');
      show('step-code');
    });
  });

  // Step 2
  $('#step-code').addEventListener('submit', (e) => {
    e.preventDefault();
    const form = e.currentTarget;
    msg(form, '');
    busy(form, async () => {
      const r = await api('verify', { email, code: $('#code').value });
      if (!r.ok) return msg(form, r.data.message || 'Could not verify the code.');
      if (r.data.alreadyRegistered) return done({ status: r.data.signupStatus, loginUrl: r.data.loginUrl, alreadyRegistered: true });
      show('step-profile');
    });
  });

  $('#resend-code').addEventListener('click', async (e) => {
    const form = $('#step-code');
    e.currentTarget.disabled = true;
    const r = await sendCode(form);
    msg(form, r.ok ? 'A new code is on its way.' : (r.data.message || 'Could not resend.'), r.ok ? 'ok' : 'err');
    setTimeout(() => { e.target.disabled = false; }, 30000);
  });

  $('#change-email').addEventListener('click', () => show('step-email'));

  // Step 3
  $('#step-profile').addEventListener('submit', (e) => {
    e.preventDefault();
    const form = e.currentTarget;
    msg(form, '');
    busy(form, async () => {
      const r = await api('register', {
        firstName: $('#firstName').value,
        lastName: $('#lastName').value,
        companyName: $('#companyName').value,
      });
      if (r.ok) return done(r.data);
      if (r.status === 401) { show('step-email'); return msg($('#step-email'), r.data.message); }
      if (r.data.error === 'email_in_use') {
        return done({ status: 'existing', loginUrl: r.data.loginUrl, alreadyRegistered: true });
      }
      if (r.data.field && $('#' + r.data.field)) $('#' + r.data.field).focus();
      msg(form, r.data.message || 'Could not create your account. Please try again.');
    });
  });

  function done({ status, loginUrl, alreadyRegistered }) {
    const title = $('#done-title'), text = $('#done-text');
    if (status === 'existing') {
      title.textContent = 'You already have an account';
      text.textContent = 'This email is already set up in the Admin Portal. Sign in to continue.';
    } else if (status === 'pending') {
      title.textContent = alreadyRegistered ? 'You\'re already registered' : 'You\'re registered';
      text.textContent = `We've emailed ${email} an invitation with a temporary password. ` +
        'Sign in to the Admin Portal with it to choose your plan and finish setup.';
    } else {
      title.textContent = 'You\'re already set up';
      text.textContent = 'Your account is active. Sign in to the Admin Portal to continue. ' +
        'If you\'ve forgotten your password, use "Forgot password" on the login page.';
    }
    $('#resend-invite-row').hidden = status !== 'pending';
    const link = $('#login-link');
    link.hidden = !loginUrl;
    if (loginUrl && /^https:\/\//.test(loginUrl)) link.href = loginUrl;
    show('step-done');
  }

  $('#resend-invite').addEventListener('click', async (e) => {
    const section = $('#step-done');
    e.currentTarget.disabled = true;
    const r = await api('resend');
    msg(section, r.ok ? 'Invitation sent again. Check your inbox and spam folder.' : (r.data.message || 'Could not resend.'), r.ok ? 'ok' : 'err');
  });
})();
