// .agent/token-tracker.js
const PRICES = {
  'claude-haiku-4-5-20251001': { in: 0.80,  out: 4.00  },
  'claude-sonnet-4-6':         { in: 3.00,  out: 15.00 },
  'claude-opus-4-6':           { in: 15.00, out: 75.00 }
};

export class TokenTracker {
  constructor(budgetUsd) {
    this.budget = budgetUsd;
    this.spent = 0;
    this.log = [];
  }

  record(model, usage) {
    const price = PRICES[model];
    const cost = (usage.input_tokens / 1e6) * price.in
               + (usage.output_tokens / 1e6) * price.out;
    this.spent += cost;
    this.log.push({ model, ...usage, cost: cost.toFixed(6) });
    console.log(`[token-tracker] ${model} — $${cost.toFixed(4)} (total: $${this.spent.toFixed(4)})`);
  }

  checkBudget() {
    if (this.spent >= this.budget) {
      throw new Error(`Budget exceeded: $${this.spent.toFixed(4)} / $${this.budget}`);
    }
  }

  report() {
    const byModel = this.log.reduce((acc, entry) => {
      acc[entry.model] = (acc[entry.model] || 0) + parseFloat(entry.cost);
      return acc;
    }, {});
    return { total_usd: this.spent.toFixed(4), by_model: byModel, calls: this.log.length };
  }
}