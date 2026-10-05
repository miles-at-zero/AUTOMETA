import { ActionError } from './base.js';

// Built-in "Autometa" integration: schedule & manual triggers, in-app notification.
export const autometa = {
  id: 'autometa',
  name: 'Autometa',
  category: 'time',
  description: 'Schedules, manual runs and notifications inside Autometa.',
  auth: { type: 'none' },
  builtin: true,
  triggers: {
    schedule: {
      label: 'On a schedule',
      description: 'Every day, on certain weekdays, at an interval, or a cron expression.',
      config: [],
      variables: ['date', 'time', 'weekday'],
    },
    manual: { label: 'When I tap Run', description: 'Runs only when you start it.', config: [], variables: [] },
  },
  actions: {
    notify: {
      label: 'Send me a notification',
      description: 'Shows in Autometa\'s notification centre for everyone in this workspace.',
      config: [
        { key: 'title', label: 'Title', type: 'text', required: true, placeholder: 'Heads up' },
        { key: 'body', label: 'Message', type: 'textarea', required: true, variables: true },
      ],
      idempotent: true,
      simulate: (cfg) => ({ title: cfg.title, body: cfg.body }),
      async execute(cfg, _conn, ctx) {
        ctx.notify({ kind: 'automation_message', severity: 'info', title: cfg.title, body: cfg.body, target: ctx.automation.id });
        return { delivered: 'in_app' };
      },
    },
  },
};

export const webhookIntegration = {
  id: 'webhook',
  name: 'Webhooks',
  category: 'web',
  description: 'Start automations from any service that can send an HTTP POST.',
  auth: { type: 'none' },
  builtin: true,
  triggers: {
    received: {
      label: 'Webhook received',
      description: 'Runs when your webhook URL receives a POST. Use fields like {{payload.priority}}.',
      config: [{ key: 'webhookId', label: 'Webhook', type: 'webhook', required: true }],
      variables: ['payload.*', 'headers.*'],
    },
  },
  actions: {},
};

export function notImplemented(name) {
  throw new ActionError(`${name} is not available on this server yet.`, { kind: 'config' });
}
