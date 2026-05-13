// Représentation des cartes : une carte = string "<rang><couleur>" (ex. "TS" = 10 de pique).
// Couleurs : c/d/h/s. Rangs : 2..9, T, J, Q, K, A.
// Affichage français : J=V (valet), Q=D (dame), K=R (roi), A=A (as).

export const SUITS = ['c', 'd', 'h', 's'];
export const RANKS = ['2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K', 'A'];
export const RANK_VALUE = Object.fromEntries(RANKS.map((r, i) => [r, i + 2])); // 2→2, A→14

export const SUIT_SYMBOLS = { c: '♣', d: '♦', h: '♥', s: '♠' };
export const SUIT_COLORS  = { c: 'black', d: 'red', h: 'red', s: 'black' };
export const RANK_DISPLAY = {
  '2': '2', '3': '3', '4': '4', '5': '5', '6': '6', '7': '7', '8': '8', '9': '9',
  T: '10', J: 'V', Q: 'D', K: 'R', A: 'A',
};

export function buildDeck() {
  const d = [];
  for (const r of RANKS) for (const s of SUITS) d.push(r + s);
  return d;
}

/** Fisher-Yates, non-mutant : retourne une nouvelle liste. */
export function shuffleDeck(arr) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export function cardRankVal(c) { return RANK_VALUE[c[0]]; }
export function cardSuit(c)    { return c[1]; }
