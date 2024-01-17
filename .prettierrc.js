module.exports = {
  bracketSpacing: true,
  printWidth: 120,
  singleQuote: true,
  trailingComma: 'es5',
  useTabs: false,
  plugins: ['prettier-plugin-solidity'],
  overrides: [
    {
      files: '*.md',
      options: {
        parser: 'markdown',
      },
    },
    {
      files: '*.sol',
      options: {
        parser: 'solidity-parse',
      },
    },
  ],
};
