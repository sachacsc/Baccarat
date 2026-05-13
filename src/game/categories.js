// Catégories d'annonces du Baccarat 3-boards, triées de la plus faible à la plus forte.
// Référence canonique : RULES.md (section "Annonces et catégories").
//
// `multi` = multiplicateur de paiement (Carré ×8, Q. Flush ×16, Royale ×20, le reste ×1).
// `CAT_RANK[id]` = index dans CATEGORIES (utilisé pour comparer la force des catégories).

export const CATEGORIES = [
  { id: 'highcard',  label: 'Hauteur',       multi: 1 },
  { id: 'pair',      label: 'Paire',         multi: 1 },
  { id: 'twopair',   label: 'Double paire',  multi: 1 },
  { id: 'trips',     label: 'Brelan',        multi: 1 },
  { id: 'straight',  label: 'Suite',         multi: 1 },
  { id: 'flush',     label: 'Couleur',       multi: 1 },
  { id: 'fullhouse', label: 'Full',          multi: 1 },
  { id: 'quads',     label: 'Carré',         multi: 8 },
  { id: 'sflush',    label: 'Quinte flush',  multi: 16 },
  { id: 'royal',     label: 'Royale',        multi: 20 },
];

export const CAT_RANK  = Object.fromEntries(CATEGORIES.map((c, i) => [c.id, i]));
export const CAT_BY_ID = Object.fromEntries(CATEGORIES.map((c)    => [c.id, c]));

// Multiplicateur affichés dans le picker du mode compteur (en plus du base ×1)
export const MULTI_OPTIONS = [
  { value: 1,  label: 'Normal',   sub: '×1'  },
  { value: 8,  label: 'Carré',    sub: '×8'  },
  { value: 16, label: 'Q. Flush', sub: '×16' },
  { value: 20, label: 'Royale',   sub: '×20' },
];
