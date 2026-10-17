import { getCurrentWeek } from '../dateUtils';

describe('getCurrentWeek', () => {
  it('should return a number between 1 and 53', () => {
    const week = getCurrentWeek();
    expect(typeof week).toBe('number');
    expect(week).toBeGreaterThanOrEqual(1);
    expect(week).toBeLessThanOrEqual(53);
  });

  it('should return correct ISO week number for a mocked date', () => {
    const RealDate = Date;

    global.Date = class extends RealDate {
      constructor() {
        super();
        return new RealDate('2025-01-04T00:00:00.000Z');
      }
    } as unknown as DateConstructor;

    const week = getCurrentWeek();
    expect(week).toBe(1);

    global.Date = RealDate;
  });

  it('should not jump backward across a Saturday-to-Sunday boundary', () => {
    const RealDate = Date;
    const mockNow = (iso: string) => {
      global.Date = class extends RealDate {
        constructor() {
          super();
          return new RealDate(iso);
        }
      } as unknown as DateConstructor;
    };

    // 2026-01-03 is a Saturday, 2026-01-04 is the following Sunday.
    mockNow('2026-01-03T00:00:00.000Z');
    const saturdayWeek = getCurrentWeek();

    mockNow('2026-01-04T00:00:00.000Z');
    const sundayWeek = getCurrentWeek();

    global.Date = RealDate;

    expect(sundayWeek).toBeGreaterThanOrEqual(saturdayWeek);
  });
});
