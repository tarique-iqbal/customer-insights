import React from 'react';
import MainLayout from '../layouts/MainLayout';
import Nav from '../components/Nav';
import { getCurrentWeek } from '../utils/dateUtils';

const Home: React.FC = () => {
  const week = getCurrentWeek();

  return (
    <MainLayout left={<Nav />}>
      <h1>Customer Satisfaction Score</h1>
      <p>
        Customer Satisfaction Score (CSAT) is a key performance indicator that measures how
        satisfied customers are with a company&apos;s products, services, or experiences.
      </p>
      <p>
        <strong>Formula:</strong> CSAT = (Number of Satisfied Customers / Total Responses) × 100
      </p>
      <p>
        <strong>Segmentation</strong> — uses a 1–5 scale:
      </p>
      <ul>
        <li>Satisfied = 4–5</li>
        <li>Neutral = 3</li>
        <li>Dissatisfied = 1–2</li>
      </ul>
      <p>
        <a href={`/csat/${week}`}>See this week&apos;s score</a>
      </p>
    </MainLayout>
  );
};

export default Home;
