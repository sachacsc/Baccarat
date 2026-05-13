// Pure helpers without DOM dependencies. Used everywhere — keep this leaf-level (no imports).

export function uid() {
  return Math.random().toString(36).slice(2, 9);
}

export function fmtMoney(v) {
  const sign = v >= 0 ? '+' : '';
  return `${sign}${v.toFixed(2)}€`;
}

export function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

/** "il y a Xmin / Xh / Xj / X mois" depuis un timestamp ms. Renvoie '' si null/0. */
export function formatAgo(ts) {
  if (!ts) return '';
  const diff = Date.now() - ts;
  const m = Math.floor(diff / 60000);
  if (m < 1)  return 'à l\'instant';
  if (m < 60) return `il y a ${m}min`;
  const h = Math.floor(m / 60);
  if (h < 24) return `il y a ${h}h`;
  const d = Math.floor(h / 24);
  if (d < 30) return `il y a ${d}j`;
  const mo = Math.floor(d / 30);
  return `il y a ${mo} mois`;
}
