// Ready-made workflows. Pure data built from the generic node types, so a
// salon, shop or clinic can copy and edit them like any other workflow.
export const TEMPLATES = [
  {
    id: 'greeting',
    name: 'Welcome new customers',
    category: 'Basics',
    description: 'Greets first-time customers and shows what you can help with.',
    requires: 'greeting',
    flow: {
      name: 'Welcome',
      trigger: { type: 'greeting' },
      nodes: [
        { id: 'hello', type: 'message', text: 'Hi {{name}}! 👋 Welcome to {{business}}.\nReply *MENU* to see what we offer, or just ask your question and we\'ll help.' },
      ],
    },
  },
  {
    id: 'away',
    name: 'Away-hours reply',
    category: 'Basics',
    description: 'Lets customers know you\'re closed and when you\'ll reply.',
    requires: 'awayHours',
    flow: {
      name: 'Away hours',
      trigger: { type: 'away_hours' },
      nodes: [
        { id: 'closed', type: 'message', text: 'Thanks for your message, {{name}}! We\'re closed right now. We\'ll reply as soon as we open. 🙏' },
      ],
    },
  },
  {
    id: 'fallback',
    name: 'Didn\'t understand → staff',
    category: 'Basics',
    description: 'When nothing else matches, tells the customer someone will reply and alerts your team.',
    requires: 'handoff',
    flow: {
      name: 'Hand to staff',
      trigger: { type: 'fallback' },
      nodes: [
        { id: 'handoff', type: 'handoff', text: 'Thanks! A member of our team will reply shortly.', reason: 'No automation matched' },
      ],
    },
  },
  {
    id: 'restaurant_order',
    name: 'Food order (menu → order → summary)',
    category: 'Orders',
    description: 'Sends your menu, takes the item, quantity, delivery or pickup and address, confirms, then hands the order to staff.',
    requires: 'orders',
    flow: {
      name: 'Food order',
      trigger: { type: 'keyword', keywords: ['menu', 'order', 'food', 'hungry'], match: 'contains' },
      nodes: [
        { id: 'menu', type: 'message', text: '📋 *Our menu*\n1. Jollof rice & chicken: ₦3,500\n2. Fried rice & turkey: ₦4,000\n3. Amala & ewedu: ₦2,500\n4. Small chops (10 pcs): ₦3,000' },
        { id: 'want', type: 'question', text: 'Would you like to order?', input: 'choice', saveAs: 'wants_order',
          choices: [{ label: 'Yes, order', value: 'yes' }, { label: 'Not now', value: 'no', next: 'bye' }] },
        { id: 'started', type: 'track', event: 'order_started' },
        { id: 'item', type: 'question', text: 'Great! What would you like? (reply with the item name or number)', input: 'text', saveAs: 'item' },
        { id: 'qty', type: 'question', text: 'How many?', input: 'number', min: 1, max: 50, saveAs: 'quantity' },
        { id: 'mode', type: 'question', text: 'Delivery or pickup?', input: 'choice', saveAs: 'fulfilment',
          choices: [{ label: 'Delivery', value: 'delivery' }, { label: 'Pickup', value: 'pickup', next: 'summary' }] },
        { id: 'address', type: 'question', text: 'Please send your delivery address 📍', input: 'text', minLength: 8, saveAs: 'address', saveToCustomer: true },
        { id: 'summary', type: 'message', text: '🧾 *Order summary*\nItem: {{item}}\nQuantity: {{quantity}}\nMethod: {{fulfilment_label}}\nAddress: {{address}}' },
        { id: 'confirm', type: 'question', text: 'Shall we confirm this order?', input: 'choice', saveAs: 'confirmed',
          choices: [{ label: 'Confirm ✅', value: 'yes' }, { label: 'Cancel', value: 'no', next: 'cancelled' }] },
        { id: 'tag', type: 'tag', tags: ['customer', 'ordered'] },
        { id: 'done', type: 'track', event: 'order_completed' },
        { id: 'handoff', type: 'handoff', text: 'Thank you {{name}}! 🎉 Your order is in. Our team will confirm the total and delivery time shortly.', reason: 'New order to confirm' },
        { id: 'cancelled', type: 'message', text: 'No problem, order cancelled. Reply MENU any time.', next: 'end' },
        { id: 'bye', type: 'message', text: 'Okay! Reply MENU whenever you\'re ready. 😊' },
        { id: 'end', type: 'end' },
      ],
    },
  },
  {
    id: 'lead_capture',
    name: 'Capture a lead / booking request',
    category: 'Sales',
    description: 'Asks for name, what they need and preferred day, tags them as a lead and assigns staff.',
    requires: 'customerCapture',
    flow: {
      name: 'Booking request',
      trigger: { type: 'keyword', keywords: ['book', 'booking', 'appointment', 'quote'], match: 'contains' },
      nodes: [
        { id: 'name', type: 'question', text: 'Happy to help! What\'s your name?', input: 'text', saveAs: 'name' },
        { id: 'savename', type: 'capture', field: 'name', value: '{{name}}' },
        { id: 'need', type: 'question', text: 'Thanks {{name}}. What service do you need?', input: 'text', saveAs: 'service', saveToCustomer: true },
        { id: 'when', type: 'question', text: 'Which day works best for you?', input: 'text', saveAs: 'preferred_day', saveToCustomer: true },
        { id: 'lead', type: 'capture', field: 'lead_status', value: 'new', lead: true },
        { id: 'tag', type: 'tag', tags: ['lead'] },
        { id: 'assign', type: 'assign', to: 'round_robin' },
        { id: 'ok', type: 'message', text: 'Got it! ✅ {{service}} on {{preferred_day}}. We\'ll confirm shortly.' },
        { id: 'remind', type: 'followup', minutes: 1440, ifNoReply: true, text: 'Hi {{name}}, just checking in on your {{service}} request. Still interested?' },
      ],
    },
  },
  {
    id: 'office_hours_router',
    name: 'Office hours router',
    category: 'Basics',
    description: 'During opening hours hands to staff; after hours takes a message.',
    requires: 'customerCapture',
    flow: {
      name: 'Talk to someone',
      trigger: { type: 'keyword', keywords: ['agent', 'human', 'staff', 'call me', 'talk to someone'], match: 'contains' },
      nodes: [
        { id: 'check', type: 'condition', rules: [{ if: { kind: 'business_hours', value: 'open' }, next: 'live' }], else: 'leave' },
        { id: 'live', type: 'handoff', text: 'Connecting you to our team now. 🙋', reason: 'Customer asked for a person' },
        { id: 'leave', type: 'question', text: 'We\'re closed now. Leave your message and we\'ll reply first thing when we open.', input: 'text', saveAs: 'message' },
        { id: 'tag', type: 'tag', tags: ['callback'] },
        { id: 'thanks', type: 'message', text: 'Thanks, we\'ve got it. Talk soon!' },
      ],
    },
  },
];

export const STARTER_FAQS = [
  { keywords: ['location', 'address', 'where are you'], answer: '📍 We\'re at [your address]. Reply MENU to order.' },
  { keywords: ['open', 'opening', 'hours', 'close'], answer: '🕘 We\'re open Mon–Sat, 9am–9pm.' },
  { keywords: ['pay', 'payment', 'transfer', 'account number'], answer: '💳 We accept transfer and POS. Account details are sent with your order confirmation.' },
];
