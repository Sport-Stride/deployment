// .agent/orchestrator.js
import Anthropic from '@anthropic-ai/sdk';
import { routeTask } from './model-router.js';
import { loadContext } from './context-loader.js';
import { TokenTracker } from './token-tracker.js';
import plannerPrompt from './prompts/planner.md' assert { type: 'text' };

const client = new Anthropic();

export async function orchestrate({ feature, services, budget_usd = 2.0 }) {
  const tracker = new TokenTracker(budget_usd);
  const context = await loadContext(services);  // reads CLAUDE.md files

  // STEP 1: Plan (Sonnet, once)
  const planResponse = await client.messages.create({
    model: 'claude-sonnet-4-6',
    max_tokens: 4096,
    system: plannerPrompt + '\n\n' + context.summary,
    messages: [{ role: 'user', content: `Feature: ${feature}\nAffected services: ${services?.join(', ')}` }]
  });
  tracker.record('claude-sonnet-4-6', planResponse.usage);

  const tasks = JSON.parse(planResponse.content[0].text);

  // STEP 2: Build execution waves (respect depends_on)
  const waves = buildWaves(tasks);

  const results = {};
  for (const wave of waves) {
    tracker.checkBudget();  // throws if over budget before spending more

    // Each wave runs in parallel
    const waveResults = await Promise.all(
      wave.map(task => executeTask(task, context, tracker, results))
    );
    waveResults.forEach(r => { results[r.id] = r; });
  }

  // STEP 3: Verify (Haiku for syntax, Sonnet for logic)
  const verification = await verify(results, tracker);

  return {
    tasks_completed: Object.keys(results).length,
    cost_report: tracker.report(),
    verification,
    files_changed: collectChangedFiles(results)
  };
}

async function executeTask(task, context, tracker, priorResults) {
  const tier = routeTask(task);
  const relevantContext = context.getFiles(task.context_needed);
  const priorWork = task.depends_on?.map(id => priorResults[id]?.output).join('\n') ?? '';

  const response = await client.messages.create({
    model: tier.model,
    max_tokens: Math.min(task.estimated_tokens * 1.3, 4096),  // 30% buffer
    system: `You are implementing a specific task. Output ONLY the code changes in unified diff format.
Task: ${task.title}
Service: ${task.service}
Acceptance: ${task.acceptance_criteria}`,
    messages: [{
      role: 'user',
      content: `Context:\n${relevantContext}\n\nPrior work:\n${priorWork}\n\nImplement: ${task.title}`
    }]
  });

  tracker.record(tier.model, response.usage);
  return { id: task.id, output: response.content[0].text, model_used: tier.model };
}