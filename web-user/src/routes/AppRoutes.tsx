import React from 'react';
import { Routes, Route } from 'react-router-dom';

import Home from '@/pages/Home';
import About from '@/pages/About';
import ContactUs from '@/pages/ContactUs';
import CsatDetails from '@/pages/CsatDetails';

const AppRoutes: React.FC = () => (
  <Routes>
    <Route path="/" element={<Home />} />
    <Route path="/about" element={<About />} />
    <Route path="/contact-us" element={<ContactUs />} />
    <Route path="/csat/:week" element={<CsatDetails />} />
    <Route path="/csat/:year/:week" element={<CsatDetails />} />
  </Routes>
);

export default AppRoutes;
