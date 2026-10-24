const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(__dirname + '/../modules/edge/spa-rewrite.js', 'utf8'), context);
for (const [uri, expected] of [
  ['/', '/index.html'], ['/broadcasts/3/', '/index.html'],
  ['/broadcasts/3', '/index.html'], ['/user/a.b/profile', '/index.html'],
  ['/assets/app.js', '/assets/app.js'], ['/favicon.ico', '/favicon.ico'],
]) {
  test(`SPA 경로 ${uri}`, () => {
    const request = {uri, querystring: {search: {value: 'hello'}}};
    const result = context.handler({request});
    assert.equal(result.uri, expected);
    assert.equal(result.querystring.search.value, 'hello');
  });
}
