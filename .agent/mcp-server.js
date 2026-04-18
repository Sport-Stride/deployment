// .agent/mcp-server.js
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { orchestrate } from './orchestrator.js';

const server = new Server({ name: 'coachify-agent', version: '1.0.0' }, {
  capabilities: { tools: {} }
});

server.setRequestHandler('tools/list', async () => ({
  tools: [
    {
      name: 'integrate_feature',
      description: 'Decomposes and implements a large feature across all relevant services',
      inputSchema: {
        type: 'object',
        properties: {
          feature: { type: 'string', description: 'Feature description' },
          services: { type: 'array', items: { type: 'string' }, description: 'Which APIs are affected' },
          budget_usd: { type: 'number', description: 'Max token spend in USD (default: 2.0)' }
        },
        required: ['feature']
      }
    }
  ]
}));

server.setRequestHandler('tools/call', async ({ params }) => {
  if (params.name === 'integrate_feature') {
    const result = await orchestrate(params.arguments);
    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);