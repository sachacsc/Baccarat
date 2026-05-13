// Évaluation de mains de poker (5 cartes) + helpers pour comparer / valider / chercher la nuts.
// Indépendant du DOM, du state, et de Supabase. Réutilisé côté host (validation), côté client
// (auto-pick + nuts theorique), et bientôt côté server (RPC record_manche replay).
//
// Forme d'un résultat d'évaluation : { cat: 'royal'|'sflush'|..., ranks: [int, ...] }
//   - cat = catégorie (cf. categories.js)
//   - ranks = ordres de tie-break (kicker à kicker), de la plus signifiante à la moins

import { buildDeck, cardRankVal, cardSuit } from './deck.js';
import { CAT_BY_ID, CAT_RANK } from './categories.js';

/** Évalue exactement 5 cartes. Renvoie {cat, ranks}. */
export function evaluate5(cards) {
  const ranks = cards.map(cardRankVal).sort((a, b) => b - a);
  const suits = cards.map(cardSuit);
  const isFlush = suits.every((s) => s === suits[0]);
  const counts = {};
  for (const r of ranks) counts[r] = (counts[r] || 0) + 1;
  const countArr = Object.entries(counts)
    .map(([r, c]) => ({ r: parseInt(r, 10), c }))
    .sort((a, b) => b.c - a.c || b.r - a.r);
  const uniq = [...new Set(ranks)].sort((a, b) => b - a);
  let straightHigh = 0;
  if (uniq.length === 5) {
    if (uniq[0] - uniq[4] === 4) straightHigh = uniq[0];
    // A-2-3-4-5 = wheel : l'as fait office de 1
    if (uniq[0] === 14 && uniq[1] === 5 && uniq[2] === 4 && uniq[3] === 3 && uniq[4] === 2) {
      straightHigh = 5;
    }
  }
  const isStraight = straightHigh > 0;
  if (isStraight && isFlush) {
    if (straightHigh === 14) return { cat: 'royal', ranks: [14] };
    return { cat: 'sflush', ranks: [straightHigh] };
  }
  if (countArr[0].c === 4) {
    return { cat: 'quads', ranks: [countArr[0].r, countArr[1].r] };
  }
  if (countArr[0].c === 3 && countArr[1].c === 2) {
    return { cat: 'fullhouse', ranks: [countArr[0].r, countArr[1].r] };
  }
  if (isFlush)    return { cat: 'flush',    ranks };
  if (isStraight) return { cat: 'straight', ranks: [straightHigh] };
  if (countArr[0].c === 3) {
    return { cat: 'trips', ranks: [countArr[0].r, countArr[1].r, countArr[2].r] };
  }
  if (countArr[0].c === 2 && countArr[1].c === 2) {
    return { cat: 'twopair', ranks: [countArr[0].r, countArr[1].r, countArr[2].r] };
  }
  if (countArr[0].c === 2) {
    return { cat: 'pair', ranks: [countArr[0].r, countArr[1].r, countArr[2].r, countArr[3].r] };
  }
  return { cat: 'highcard', ranks };
}

/** Meilleure combinaison 5-card parmi N cartes (N ≥ 5). */
export function evaluateBest(cards) {
  if (!cards || cards.length < 5) return null;
  if (cards.length === 5) return evaluate5(cards);
  let best = null;
  const n = cards.length;
  for (let a = 0; a < n - 4; a++)
    for (let b = a + 1; b < n - 3; b++)
      for (let c = b + 1; c < n - 2; c++)
        for (let d = c + 1; d < n - 1; d++)
          for (let e = d + 1; e < n; e++) {
            const ev = evaluate5([cards[a], cards[b], cards[c], cards[d], cards[e]]);
            if (!best || compareHands(ev, best) > 0) best = ev;
          }
  return best;
}

/** Compare deux mains : > 0 si a > b, < 0 si a < b, 0 si égalité parfaite. */
export function compareHands(a, b) {
  const ar = CAT_RANK[a.cat], br = CAT_RANK[b.cat];
  if (ar !== br) return ar - br;
  const len = Math.max(a.ranks.length, b.ranks.length);
  for (let i = 0; i < len; i++) {
    const av = a.ranks[i] || 0, bv = b.ranks[i] || 0;
    if (av !== bv) return av - bv;
  }
  return 0;
}

/** Vrai si la main composée des hole+board permet AU MOINS la catégorie annoncée. */
export function validateAnnounce(announcedCat, holeCards, boardCards) {
  if (announcedCat === 'skip') return false;
  if (!CAT_BY_ID[announcedCat]) return false;
  const best = evaluateBest([...holeCards, ...boardCards]);
  return !!best && CAT_RANK[best.cat] >= CAT_RANK[announcedCat];
}

// Nuts THÉORIQUE du board, du point de vue d'un observateur précis.
//
// Le nuts représente la meilleure main qu'un adversaire POURRAIT avoir, étant donné
// ce qu'on voit (les 3 boards) et ce qu'on tient en main (nos cartes ne sont pas dispo
// pour quelqu'un d'autre). Ça reste théorique : on ne sait pas où sont les cartes
// non visibles (autres mains, brûlées, deck non distribué) — toutes y sont candidates.
//
// Pool = deck (52) − 15 cartes des 3 boards − cartes de la main du viewer (4-6).
// Pour chaque paire du pool, on évalue (paire + 5 cartes du board courant).
// Coût : pool ≈ 31-37 cartes → C(n,2) ≈ 465-666 paires × evaluateBest sur 7 cartes.
//
// Appelée côté client à chaque render — chaque joueur voit sa propre nuts.
export function computeNuts(boardCards, allCommunityCards, viewerHand) {
  if (!boardCards || boardCards.length < 5) return null;
  const used = new Set();
  for (const cs of (allCommunityCards || [])) {
    if (Array.isArray(cs)) for (const c of cs) used.add(c);
  }
  for (const c of (viewerHand || [])) used.add(c);
  const pool = buildDeck().filter((c) => !used.has(c));
  let best = null;
  for (let i = 0; i < pool.length; i++) {
    for (let j = i + 1; j < pool.length; j++) {
      const ev = evaluateBest([pool[i], pool[j], ...boardCards]);
      if (!best || compareHands(ev, best.ev) > 0) {
        best = { cards: [pool[i], pool[j]], ev };
      }
    }
  }
  return best ? { cat: best.ev.cat, ranks: best.ev.ranks, cards: best.cards } : null;
}

/** Trouve les 2 cartes optimales (parmi la main) qui satisfont l'annonce et maximisent la force.
 *  Utilisé pour la catégorie Hauteur (auto-pick). Renvoie null si l'annonce n'est pas atteignable. */
export function autoPickCards(holeCards, boardCards, announcedCat) {
  if (announcedCat === 'skip') return [];
  if (!CAT_BY_ID[announcedCat]) return null;
  if (holeCards.length < 2) return null;
  let best = null;
  for (let i = 0; i < holeCards.length; i++) {
    for (let j = i + 1; j < holeCards.length; j++) {
      const cards = [holeCards[i], holeCards[j]];
      const ev = evaluateBest([...cards, ...boardCards]);
      if (ev && CAT_RANK[ev.cat] >= CAT_RANK[announcedCat]) {
        if (!best || compareHands(ev, best.ev) > 0) best = { cards, ev };
      }
    }
  }
  return best ? best.cards : null;
}
