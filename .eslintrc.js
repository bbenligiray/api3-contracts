module.exports = {
  extends: ['./node_modules/@api3/commons/dist/eslint/universal'],
  parserOptions: {
    project: ['./tsconfig.json'],
  },
  rules: {
    'unicorn/filename-case': 'off',

    '@typescript-eslint/max-params': 'off',
    '@typescript-eslint/no-unsafe-call': 'off',
  },
};
