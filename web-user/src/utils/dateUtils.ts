export const getCurrentWeek = (): number => {
  const now = new Date();
  const jan1 = new Date(now.getFullYear(), 0, 1);
  const days = Math.floor((+now - +jan1) / 86400000);
  return Math.ceil((jan1.getDay() + 1 + days) / 7);
};
