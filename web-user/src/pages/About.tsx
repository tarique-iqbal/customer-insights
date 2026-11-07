import React from 'react';
import MainLayout from '../layouts/MainLayout';
import Nav from '../components/Nav';

const About: React.FC = () => {
  return (
    <MainLayout left={<Nav />}>
      <h1>About This App</h1>
      <p>
        This app tracks Customer Satisfaction Score (CSAT) week over week. Survey responses are
        imported and aggregated into a single score per week, so you can see how satisfaction is
        trending without digging through raw survey data yourself.
      </p>
      <p>What you can do here:</p>
      <ul>
        <li>See the current week&apos;s score from the Home page.</li>
        <li>Look up any past week&apos;s score directly by week number, or by year and week.</li>
      </ul>
      <p>
        Have a question or found something that looks wrong? <a href="/contact-us">Contact us</a>.
      </p>
    </MainLayout>
  );
};

export default About;
