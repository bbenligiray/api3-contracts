module.exports = {
  extends: ['./node_modules/@api3/commons/dist/eslint/universal'],
  parserOptions: {
    project: ['./tsconfig.eslint.json'],
  },
  rules: {
    'unicorn/filename-case': 'off',
    'unicorn/prefer-export-from': 'off',

    '@typescript-eslint/max-params': 'off',
    '@typescript-eslint/no-unsafe-call': 'off',
  },
};
