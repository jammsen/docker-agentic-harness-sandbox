import clsx from 'clsx';
import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';
import styles from './index.module.css';

const features = [
  ['Browser terminal', 'Use Claude Code, OpenCode, or OMP through WeTTY over HTTPS.'],
  ['Your model endpoint', 'Connect every supported agent to a self-hosted vLLM or compatible API.'],
  ['Persistent workspace', 'Keep projects, sessions, and uploads on host-mounted directories.'],
];

export default function Home() {
  return (
    <Layout title="Home" description="Documentation for the Docker agentic harness sandbox">
      <header className={clsx('hero hero--primary', styles.heroBanner)}>
        <div className="container">
          <Heading as="h1" className="hero__title">Agentic Harness Sandbox</Heading>
          <p className="hero__subtitle">A hardened Docker workspace for local agentic coding tools.</p>
          <Link className="button button--secondary button--lg" to="/docs/getting-started">
            Get started
          </Link>
        </div>
      </header>
      <main className={styles.features}>
        <div className="container">
          <div className="row">
            {features.map(([title, description]) => (
              <div className="col col--4" key={title}>
                <div className={styles.featureCard}>
                  <Heading as="h2">{title}</Heading>
                  <p>{description}</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </main>
    </Layout>
  );
}
