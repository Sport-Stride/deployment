// .agent/model-router.js
const TIERS = {
  CHEAP:    { model: 'claude-haiku-4-5-20251001', inputCost: 0.80,  outputCost: 4.00  },
  STANDARD: { model: 'claude-sonnet-4-6',          inputCost: 3.00,  outputCost: 15.00 },
  PREMIUM:  { model: 'claude-opus-4-6',             inputCost: 15.00, outputCost: 75.00 }
};

// Rules evaluated in order — first match wins
const ROUTING_RULES = [
  { tier: 'CHEAP',    match: (t) => t.tags.includes('boilerplate') },
  { tier: 'CHEAP',    match: (t) => t.tags.includes('test_generation') },
  { tier: 'CHEAP',    match: (t) => t.tags.includes('crud') && !t.tags.includes('complex_relations') },
  { tier: 'CHEAP',    match: (t) => t.tags.includes('dto') || t.tags.includes('migration') },
  { tier: 'CHEAP',    match: (t) => t.complexity <= 2 },
  { tier: 'STANDARD', match: (t) => t.tags.includes('integration') },
  { tier: 'STANDARD', match: (t) => t.tags.includes('auth') || t.tags.includes('middleware') },
  { tier: 'STANDARD', match: (t) => t.complexity <= 4 },
  { tier: 'PREMIUM',  match: (t) => t.tags.includes('architecture_decision') },
  { tier: 'PREMIUM',  match: (t) => t.tags.includes('security_review') },
  { tier: 'PREMIUM',  match: (t) => t.priority === 'critical' && t.complexity >= 5 },
  { tier: 'STANDARD', match: () => true }  // fallback
];

export function routeTask(task) {
  const rule = ROUTING_RULES.find(r => r.match(task));
  return TIERS[rule.tier];
}