import React, { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { getCsatByWeek, getCsatByYearWeek, CsatEntry } from '@/api/csatService';
import MainLayout from '@/layouts/MainLayout';
import Nav from '@/components/Nav';

const CsatDetails: React.FC = () => {
  const { year, week } = useParams<{ year?: string; week: string }>();
  const [data, setData] = useState<CsatEntry | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!week) return;

    const controller = new AbortController();

    setData(null);
    setError(null);

    const request = year
      ? getCsatByYearWeek(year, week, controller.signal)
      : getCsatByWeek(week, controller.signal);

    request
      .then(setData)
      .catch((err) => {
        if (err.name !== 'AbortError') {
          setError(err.message);
        }
      });

    return () => {
      controller.abort();
    };
  }, [year, week]);

  return (
    <MainLayout left={<Nav />}>
      <h1>CSAT Details</h1>

      {!week && <p>Missing CSAT week.</p>}
      {error && <p>{error}</p>}
      {!data && !error && <p>Loading CSAT entry...</p>}

      {data && (
        <div>
          <h2>CSAT week #{data.week}{data.year ? ` (${data.year})` : ''}</h2>
          <p><strong>Score:</strong> {data.score}%</p>
        </div>
      )}
    </MainLayout>
  );
};

export default CsatDetails;
