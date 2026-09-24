const zeroDecimalCurrencies = new Set([
  "BIF",
  "CLP",
  "DJF",
  "GNF",
  "JPY",
  "KMF",
  "KRW",
  "PYG",
  "RWF",
  "UGX",
  "VND",
  "VUV",
  "XAF",
  "XOF",
  "XPF",
]);

const threeDecimalCurrencies = new Set([
  "BHD",
  "IQD",
  "JOD",
  "KWD",
  "LYD",
  "OMR",
  "TND",
]);

export function currencyFractionDigits(currency: string) {
  const normalized = currency.toUpperCase();

  if (zeroDecimalCurrencies.has(normalized)) return 0;
  if (threeDecimalCurrencies.has(normalized)) return 3;

  // LevelledUp's approved V1 convention stores PKR and ordinary currencies
  // in hundredths: PKR 150 is persisted as 15000 minor units.
  return 2;
}
