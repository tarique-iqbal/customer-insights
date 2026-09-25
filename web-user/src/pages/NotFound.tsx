import React from 'react';
import MainLayout from '@/layouts/MainLayout';
import Nav from '@/components/Nav';

const NotFound: React.FC = () => {
  return (
    <MainLayout left={<Nav />}>
      <h1>Page Not Found</h1>
      <p>The page you are looking for does not exist.</p>
    </MainLayout>
  );
};

export default NotFound;
