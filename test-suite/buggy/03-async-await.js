// ============================================================================
// TEST SUITE: ASYNC/AWAIT & PROMISE PITFALLS (BUGGY CODE)
// Expected: Multiple CRITICAL and WARNING issues
// ============================================================================

// BUG 1: await in non-async function (SyntaxError!)
function fetchUser(id) {
  const response = await fetch(`/api/users/${id}`);  // CRITICAL: SyntaxError!
  return response.json();
}

// BUG 2: Missing await on async function call
async function saveUser(data) {
  const validated = validateUser(data);  // Should be: await validateUser(data)
  await db.save(validated);  // Saves undefined!
}

// BUG 3: Promise.then() without .catch()
function loadData() {
  fetch('/api/data')
    .then(res => res.json())
    .then(data => processData(data));  // Unhandled rejection!
}

// BUG 4: Multiple promises without catch
api.getUser(id)
  .then(user => updateUI(user));  // No error handling

api.getData()
  .then(data => transform(data))
  .then(result => save(result));  // No error handling

// BUG 5: await in loop (performance issue)
async function processItems(items) {
  for (const item of items) {
    await processItem(item);  // Sequential! Should use Promise.all()
  }
}

// BUG 6: Floating promise (not awaited)
async function handleSubmit() {
  saveToDatabase(data);  // Forgot await - continues without waiting!
  redirectToHome();
}

// BUG 7: try/catch with no error handling
async function getData() {
  try {
    const result = await api.fetch();
    return result;
  } catch (e) {
    // Empty catch - swallows errors!
  }
}

// BUG 8: Promise constructor anti-pattern
function fetchData() {
  return new Promise((resolve, reject) => {
    fetch('/api/data')  // Already returns a promise - this is redundant
      .then(res => resolve(res))
      .catch(err => reject(err));
  });
}

// BUG 9: Mixing async/await with .then()
async function mixedApproach() {
  const user = await getUser();
  return processUser(user).then(result => {  // Pick one style!
    return result;
  });
}

// BUG 10: Race condition - concurrent modification
async function updateCounter() {
  const current = await getCount();
  await setCount(current + 1);  // Race: another request might update in between
}

// BUG 11: Async function not awaited in forEach
async function processAll(items) {
  items.forEach(async (item) => {
    await process(item);  // forEach doesn't wait for async!
  });
  console.log('Done');  // Logs before processing finishes!
}

// BUG 12: Promise.race without error handling
async function loadFastest() {
  const result = await Promise.race([
    fetch('/api/v1/data'),
    fetch('/api/v2/data')
  ]);  // No error handling for the loser
  return result;
}

// BUG 13: Forgotten return in async function
async function saveData(data) {
  await db.save(data);  // No return - returns Promise<undefined>
}

// BUG 14: await in constructor (not allowed!)
class DataLoader {
  constructor(id) {
    this.data = await this.loadData(id);  // CRITICAL: Can't use await in constructor
  }
}
