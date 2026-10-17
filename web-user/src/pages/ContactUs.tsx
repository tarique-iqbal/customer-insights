import React, { useState } from 'react';
import { useForm, SubmitHandler } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { sendContactMessage, ContactFormValues } from '@/api/contactUs';
import MainLayout from '@/layouts/MainLayout';
import Nav from '@/components/Nav';
import '@/pages/ContactUs.css';

// Mirrors api-service's Name/Message value objects
// (src/Domain/Contact/ValueObject/{Name,Message}.php) so invalid input is
// caught client-side instead of round-tripping to the server first.
const NAME_FORBIDDEN_CHARS = /[0-9^<,@/{}()[\]!&`~*$%?=>:|;#"]/;

const contactSchema = z.object({
  name: z
    .string()
    .trim()
    .min(2, 'Name must be at least 2 characters long')
    .max(100, 'Name must not exceed 100 characters')
    .refine((value) => !NAME_FORBIDDEN_CHARS.test(value), {
      message: 'Special characters and numbers are not allowed in the name',
    }),
  email: z.string().email('Invalid email format'),
  message: z
    .string()
    .trim()
    .min(80, 'Message must be at least 80 characters long')
    .max(2000, 'Message must not exceed 2000 characters'),
});

const ContactUs: React.FC = () => {
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
    reset,
  } = useForm<ContactFormValues>({
    resolver: zodResolver(contactSchema),
  });

  const [submitted, setSubmitted] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);

  const onSubmit: SubmitHandler<ContactFormValues> = async (data) => {
    try {
      await sendContactMessage(data);
      setSubmitted(true);
      reset();
    } catch (err) {
      setServerError((err as { message?: string }).message ?? 'Something went wrong');
    }
  };

  if (submitted) {
    return (
      <MainLayout left={<Nav />}>
        <div className="success-message">
          <h2>Thank you!</h2>
          <p>Your message has been sent successfully.</p>
        </div>
      </MainLayout>
    );
  }

  return (
    <MainLayout left={<Nav />}>
      <div className="contact-container">
        <h1>Contact Us</h1>
        {serverError && <p className="error">{serverError}</p>}

        <form onSubmit={handleSubmit(onSubmit)} noValidate>
          <div className="form-field">
            <label htmlFor="name">Name</label>
            <input
              id="name"
              {...register('name')}
              disabled={isSubmitting}
              aria-invalid={!!errors.name}
            />
            {errors.name && <p className="error">{errors.name.message}</p>}
          </div>

          <div className="form-field">
            <label htmlFor="email">Email</label>
            <input
              id="email"
              type="email"
              {...register('email')}
              disabled={isSubmitting}
              aria-invalid={!!errors.email}
            />
            {errors.email && <p className="error">{errors.email.message}</p>}
          </div>

          <div className="form-field">
            <label htmlFor="message">Message</label>
            <textarea
              id="message"
              {...register('message')}
              disabled={isSubmitting}
              aria-invalid={!!errors.message}
            />
            {errors.message && <p className="error">{errors.message.message}</p>}
          </div>

          <button type="submit" disabled={isSubmitting}>
            {isSubmitting ? 'Sending...' : 'Send'}
          </button>
        </form>
      </div>
    </MainLayout>
  );
};

export default ContactUs;
