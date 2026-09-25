import http from '@/api/http';

export interface CsatEntry {
  week: number;
  year?: number | null;
  score: number;
}

const fetchCsat = (path: string, signal?: AbortSignal): Promise<CsatEntry> =>
  http
    .get(path, { signal })
    .then((res) => res.data)
    .catch((error) => {
      if (error.name === 'CanceledError' || error.code === 'ERR_CANCELED') {
        throw new DOMException('Request aborted', 'AbortError');
      }
      throw new Error(`Failed to fetch CSAT: ${error.message}`);
    });

export const getCsatByWeek = (
  week: string,
  signal?: AbortSignal
): Promise<CsatEntry> => fetchCsat(`/api/csat/${Number(week)}`, signal);

export const getCsatByYearWeek = (
  year: string,
  week: string,
  signal?: AbortSignal
): Promise<CsatEntry> =>
  fetchCsat(`/api/csat/${Number(year)}/${Number(week)}`, signal);
