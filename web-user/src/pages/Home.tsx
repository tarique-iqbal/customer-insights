import React from 'react';
import MainLayout from '../layouts/MainLayout';
import Nav from '../components/Nav';

const Home: React.FC = () => {
  return (
    <MainLayout left={<Nav />}>
      <h1>Welcome - Home Page</h1>
      <p>Customer Satisfaction Score (CSAT) is a key performance indicator that measures how satisfied customers are with a company&apos;s products, services, or experiences.</p>
    </MainLayout>
  );
};

export default Home;
