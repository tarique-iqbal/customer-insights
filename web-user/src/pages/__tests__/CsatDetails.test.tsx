import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { describe, it, vi, beforeEach, expect } from 'vitest';
import CsatDetails from '@/pages/CsatDetails';
import { getCsatByWeek, getCsatByYearWeek } from '@/api/csatService';

vi.mock('@/api/csatService', () => ({
  getCsatByWeek: vi.fn(),
  getCsatByYearWeek: vi.fn(),
}));

const mockedGetCsatByWeek = getCsatByWeek as vi.Mock;
const mockedGetCsatByYearWeek = getCsatByYearWeek as vi.Mock;

const renderWithRoute = (path: string) =>
  render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/csat/:week" element={<CsatDetails />} />
        <Route path="/csat/:year/:week" element={<CsatDetails />} />
      </Routes>
    </MemoryRouter>
  );

describe('CsatDetails', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('shows loading and then data on success', async () => {
    mockedGetCsatByWeek.mockResolvedValueOnce({ week: 11, score: 85 });

    renderWithRoute('/csat/11');

    expect(screen.getByText('Loading CSAT entry...')).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.getByText('CSAT week #11')).toBeInTheDocument();
      expect(screen.getByText(/85%/)).toBeInTheDocument();
    });
  });

  it('requests the given year and shows it next to the week', async () => {
    mockedGetCsatByYearWeek.mockResolvedValueOnce({ week: 21, year: 2022, score: 70 });

    renderWithRoute('/csat/2022/21');

    await waitFor(() => {
      expect(screen.getByText('CSAT week #21 (2022)')).toBeInTheDocument();
      expect(screen.getByText(/70%/)).toBeInTheDocument();
    });

    expect(mockedGetCsatByYearWeek).toHaveBeenCalledWith('2022', '21', expect.any(AbortSignal));
    expect(mockedGetCsatByWeek).not.toHaveBeenCalled();
  });

  it('shows error on API failure', async () => {
    mockedGetCsatByWeek.mockRejectedValueOnce(new Error('API failed'));

    renderWithRoute('/csat/11');

    await waitFor(() => {
      expect(screen.getByText('API failed')).toBeInTheDocument();
    });
  });

  it('shows "Missing CSAT week" when no week param', () => {
    render(
      <MemoryRouter initialEntries={['/csat/']}>
        <Routes>
          <Route path="/csat/" element={<CsatDetails />} />
        </Routes>
      </MemoryRouter>
    );

    expect(screen.getByText('Missing CSAT week.')).toBeInTheDocument();
  });

  it('ignores AbortError without setting error state', async () => {
    const abortError = new DOMException('Request aborted', 'AbortError');
    mockedGetCsatByWeek.mockRejectedValueOnce(abortError);

    renderWithRoute('/csat/11');

    await waitFor(() => {
      expect(screen.queryByText('Request aborted')).not.toBeInTheDocument();
    });
  });
});
