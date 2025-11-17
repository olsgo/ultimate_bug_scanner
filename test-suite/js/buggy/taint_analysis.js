// Buggy taint-analysis fixture: several unsafe source -> sink flows
const express = require('express');
const { exec } = require('child_process');
const db = require('./fake-db');

const router = express.Router();

router.post('/comment', (req, res) => {
  const comment = req.body.text; // taint source
  const html = `<div class="comment">${comment}</div>`;
  res.send(html); // unsanitized HTML response
});

router.get('/preview', (req, res) => {
  const snippet = req.query.html;
  document.getElementById('preview').innerHTML = snippet; // DOM XSS sink
  res.send('ok');
});

router.get('/search', (req, res) => {
  const sql = "SELECT * FROM posts WHERE slug = '" + req.params.slug + "'";
  db.query(sql); // SQL injection risk
  res.send('done');
});

router.get('/exec', (req, res) => {
  const cmd = 'ls ' + req.query.path;
  exec(cmd, err => {
    if (err) {
      console.error(err);
    }
    res.send('executed');
  });
});

const queryString = window.location.search; // browser source
if (queryString) {
  document.write('<p>' + queryString + '</p>');
}

module.exports = router;
