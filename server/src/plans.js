// What each plan CAN DO. Deliberately contains no prices: prices live in
// pricing.js (and can be overridden by env) so a price test never touches
// entitlement logic.

export const FEATURES = {
  autoReplies: 'Keyword auto replies',
  faq: 'FAQ answers',
  greeting: 'Greeting for new customers',
  awayHours: 'Away-hours replies & business hours',
  handoff: 'Hand off to a human',
  customerCapture: 'Questions & customer capture',
  tagging: 'Customer tags',
  orders: 'Order workflows & order tracking',
  followups: 'Delays & follow-up reminders',
  analytics: 'Analytics dashboard',
  templates: 'Ready-made business templates',
  team: 'Staff members & assignment',
  advancedAnalytics: 'Advanced analytics (per-flow, response times, export)',
  ai: 'AI assistant',
  advancedPermissions: 'Advanced permissions (agents see only assigned chats)',
  audit: 'Audit history',
  integrations: 'Integrations (outgoing webhooks)',
  multiBusiness: 'Multiple businesses / numbers',
};

const FREE = ['autoReplies', 'faq', 'greeting', 'awayHours', 'handoff'];
const PRO = [...FREE, 'customerCapture', 'tagging', 'orders', 'followups', 'analytics', 'templates', 'team'];
const BUSINESS = [...PRO, 'advancedAnalytics', 'ai', 'advancedPermissions', 'audit', 'integrations', 'multiBusiness'];

// null = unlimited
export const PLANS = {
  free: {
    id: 'free', name: 'Free', rank: 0, features: FREE,
    limits: { businesses: 1, members: 1, flows: 3, nodesPerFlow: 6, faqs: 10, aiCallsPerMonth: 0, customers: 500 },
  },
  pro: {
    id: 'pro', name: 'Pro', rank: 1, features: PRO,
    limits: { businesses: 1, members: 5, flows: null, nodesPerFlow: 40, faqs: null, aiCallsPerMonth: 0, customers: null },
  },
  business: {
    id: 'business', name: 'Business', rank: 2, features: BUSINESS,
    limits: { businesses: 5, members: 25, flows: null, nodesPerFlow: 120, faqs: null, aiCallsPerMonth: 1500, customers: null },
  },
};

// Which feature each workflow node / trigger needs.
export const NODE_FEATURE = {
  message: 'autoReplies',
  condition: 'autoReplies',
  end: 'autoReplies',
  goto: 'autoReplies',
  handoff: 'handoff',
  question: 'customerCapture',
  capture: 'customerCapture',
  tag: 'tagging',
  track: 'orders',
  delay: 'followups',
  followup: 'followups',
  assign: 'team',
  ai_reply: 'ai',
  webhook: 'integrations',
};

export const TRIGGER_FEATURE = {
  keyword: 'autoReplies',
  greeting: 'greeting',
  away_hours: 'awayHours',
  fallback: 'autoReplies',
  button: 'autoReplies',
};
