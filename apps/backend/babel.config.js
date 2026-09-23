// Project-wide Babel config (replaces .babelrc).
//
// A project-wide config is needed, not a .babelrc, because a .babelrc never
// applies inside node_modules. Tests must compile a few ESM-only dependencies
// (otplib -> @scure/base, @noble/hashes) that Jest's CommonJS runtime cannot
// load as-is; see transformIgnorePatterns in the Jest configs. At runtime Node
// 24 loads them natively and @babel/register still skips node_modules.
module.exports = {
  presets: ['@babel/preset-env'],
  plugins: [
    ['@babel/plugin-proposal-decorators', { legacy: true }],
    ['@babel/plugin-transform-runtime', { regenerator: true }],
  ],
};
