// Rendering des cartes en HTML (string templates) + helpers URL.
// Aucune dépendance DOM directe — la fonction renvoie une string que l'appelant injecte.
//
// Assets : Xadeck/xCards via jsdelivr, mêmes dimensions natives 750×1050 (ratio 5:7)
// pour les faces et le dos → la boîte .card est en 5:7 et object-fit:cover s'applique
// sans crop visible.

import { buildDeck, SUIT_COLORS, RANK_DISPLAY, SUIT_SYMBOLS } from './deck.js';

export const CARDS_CDN_BASE = 'https://cdn.jsdelivr.net/gh/Xadeck/xCards@master/png';

export function cardImgURL(c) {
  return `${CARDS_CDN_BASE}/face/${c[0]}${c[1].toUpperCase()}@2x.png`;
}
export function cardBackURL() {
  return `${CARDS_CDN_BASE}/back/bicycle_blue@2x.png`;
}

let cardsPreloaded = false;
/** Précharge les 52 faces + le dos dans le cache navigateur. Idempotent. */
export function preloadCardImages() {
  if (cardsPreloaded) return;
  cardsPreloaded = true;
  buildDeck().forEach((c) => { const img = new Image(); img.src = cardImgURL(c); });
  const back = new Image(); back.src = cardBackURL();
}

/** Renvoie l'HTML d'une carte. Options :
 *   - faceDown (bool) : affiche le dos (peut être combiné avec flipKey, animate, delay)
 *   - flipKey (string) : si fourni, attache data-flip-card pour le click-to-flip (Flash mode)
 *   - placeholder (bool) : carte vide pointillée (slot vide d'un board)
 *   - animate (bool) : ajoute la classe anim-in (flip-in animation)
 *   - delay (ms) : staggered animation-delay
 *   - selectable (bool) : style cliquable
 *   - selected (bool) : style sélectionné (sortie en haut)
 *   - disabled (bool) : opacité réduite, pointer-events:none
 *   - data (bool) : ajoute data-card="<rang+suite>" sur la racine */
export function renderCardHTML(c, opts) {
  opts = opts || {};
  // NB: les handlers inline `onload`/`onerror` font une garde `this.parentNode &&` car
  // sur Safari iOS, quand l'image est déjà en cache, l'événement load peut être déclenché
  // SYNCHRONIQUEMENT au moment où on parse le HTML, AVANT que l'IMG soit insérée dans le DOM.
  // Dans ce cas this.parentNode est null et `this.parentNode.classList` plante.
  if (opts.faceDown) {
    const flipAttr = opts.flipKey ? ` data-flip-card="${opts.flipKey}"` : '';
    const clickCls = opts.flipKey ? ' flippable' : '';
    const anim = opts.animate ? ' anim-in' : '';
    const styleAttr = (opts.animate && opts.delay) ? ` style="animation-delay:${opts.delay}ms;"` : '';
    return `<div class="card back${clickCls}${anim}"${styleAttr}${flipAttr}><img class="card-img" src="${cardBackURL()}" onload="this.parentNode&&this.parentNode.classList.add('img-loaded')" onerror="this.style.display='none'" alt=""></div>`;
  }
  if (opts.placeholder || !c) return '<div class="card placeholder"></div>';
  const r = c[0], s = c[1];
  const color = SUIT_COLORS[s];
  const rd = RANK_DISPLAY[r];
  const sd = SUIT_SYMBOLS[s];
  const sel = opts.selected ? ' selected' : '';
  const sct = opts.selectable ? ' selectable' : '';
  const dis = opts.disabled ? ' disabled' : '';
  const anim = opts.animate ? ' anim-in' : '';
  const styleAttr = (opts.animate && opts.delay) ? ` style="animation-delay:${opts.delay}ms;"` : '';
  const dataAttr = opts.data ? ` data-card="${c}"` : '';
  const isFace = (r === 'J' || r === 'Q' || r === 'K' || r === 'A');
  const centerHTML = isFace
    ? `<div class="card-center face">${rd}<span class="face-suit">${sd}</span></div>`
    : `<div class="card-center">${sd}</div>`;
  return `<div class="card ${color}${sel}${sct}${dis}${anim}"${styleAttr}${dataAttr}><div class="card-corner card-corner-tl"><div class="card-rank">${rd}</div><div class="card-suit">${sd}</div></div>${centerHTML}<div class="card-corner card-corner-br"><div class="card-rank">${rd}</div><div class="card-suit">${sd}</div></div><img class="card-img" src="${cardImgURL(c)}" onload="this.parentNode&&this.parentNode.classList.add('img-loaded')" onerror="this.style.display='none';this.parentNode&&this.parentNode.classList.add('img-failed')" alt=""></div>`;
}
